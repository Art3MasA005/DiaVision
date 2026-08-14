"""Database schema — PRD §8.

The load-bearing decision here is the **Account / Profile split**, and it is in
from the first migration rather than retrofitted:

    Account   who logs in and who pays
    Profile   ONE PERSON'S HEALTH RECORD

Every health table keys on `profile_id`, never `account_id`. PRD §8 is blunt
that retrofitting this means touching every table and every query, so it goes
in now even though multi-profile UI is not in the first release.

Isolation is enforced by PostgreSQL row-level security on `profile_id`
(see rls.sql), not by remembering a WHERE clause in every endpoint. PRD §18
requires exactly that, plus an adversarial test proving a valid token for
profile A cannot read profile B.
"""

from __future__ import annotations

import uuid
from datetime import datetime, date

from sqlalchemy import (
    Boolean, CheckConstraint, Date, DateTime, Float, ForeignKey, Index,
    Integer, String, Text, UniqueConstraint, func,
)
from sqlalchemy.dialects.postgresql import ARRAY, JSONB, UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, relationship


class Base(DeclarativeBase):
    pass


def _pk() -> Mapped[uuid.UUID]:
    return mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)


def _now() -> Mapped[datetime]:
    return mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)


# ──────────────────────────────────────────────────────────────────────
# Identity and billing
# ──────────────────────────────────────────────────────────────────────

class Account(Base):
    """Who logs in and who pays. Carries no health data."""

    __tablename__ = "accounts"

    id: Mapped[uuid.UUID] = _pk()
    email: Mapped[str] = mapped_column(String(320), unique=True, index=True, nullable=False)
    phone: Mapped[str | None] = mapped_column(String(32), unique=True, index=True)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    auth_provider: Mapped[str] = mapped_column(String(32), default="password", nullable=False)

    # Stamped at signup and NEVER silently migrated (PRD §3.5). Retrofitting
    # residency is a rewrite; getting it right at signup costs nothing.
    home_region: Mapped[str] = mapped_column(String(2), default="bd", nullable=False)
    data_residency_zone: Mapped[str] = mapped_column(String(16), default="ap-south", nullable=False)

    locale: Mapped[str] = mapped_column(String(8), default="bn", nullable=False)
    units_prefs: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)

    subscription_status: Mapped[str] = mapped_column(String(16), default="free", nullable=False)
    subscription_expiry: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    seat_count: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    account_type: Mapped[str] = mapped_column(String(16), default="individual", nullable=False)

    # PRD §3.2 — first launch shows a blocking disclaimer that must be accepted.
    disclaimer_accepted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    created_at: Mapped[datetime] = _now()
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    owned_profiles: Mapped[list["Profile"]] = relationship(
        back_populates="owner", foreign_keys="Profile.account_id_owner"
    )

    __table_args__ = (
        CheckConstraint("account_type IN ('individual','family','clinic')",
                        name="ck_account_type"),
        CheckConstraint("subscription_status IN ('free','trial','active','past_due','cancelled')",
                        name="ck_subscription_status"),
    )


class Profile(Base):
    """One person's health record. The unit of isolation."""

    __tablename__ = "profiles"

    id: Mapped[uuid.UUID] = _pk()
    account_id_owner: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("accounts.id", ondelete="RESTRICT"), nullable=False, index=True
    )
    # Set when a self-managed member claims their own profile (PRD §3.6
    # invite-and-claim). Until then the profile is owner-administered.
    claimed_by_account_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("accounts.id", ondelete="SET NULL"), index=True
    )

    display_name: Mapped[str] = mapped_column(String(120), nullable=False)
    avatar_color: Mapped[str] = mapped_column(String(16), default="#0F766E", nullable=False)
    profile_type: Mapped[str] = mapped_column(String(16), default="self", nullable=False)

    region_pack: Mapped[str] = mapped_column(String(2), default="bd", nullable=False)

    is_managed: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    managed_attestation_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    created_at: Mapped[datetime] = _now()
    archived_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    owner: Mapped[Account] = relationship(
        back_populates="owned_profiles", foreign_keys=[account_id_owner]
    )
    health: Mapped["HealthProfile"] = relationship(
        back_populates="profile", uselist=False, cascade="all, delete-orphan"
    )

    __table_args__ = (
        CheckConstraint("profile_type IN ('self','member','dependent','patient')",
                        name="ck_profile_type"),
        # A managed profile must record when the attestation was made (PRD §3.6).
        CheckConstraint("NOT is_managed OR managed_attestation_at IS NOT NULL",
                        name="ck_managed_requires_attestation"),
    )


class ProfileMembership(Base):
    """Who may see or act on a profile. Explicit, scoped, revocable, time-boundable."""

    __tablename__ = "profile_memberships"

    id: Mapped[uuid.UUID] = _pk()
    profile_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"), nullable=False, index=True
    )
    account_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("accounts.id", ondelete="CASCADE"), nullable=False, index=True
    )
    role: Mapped[str] = mapped_column(String(16), nullable=False)
    scope: Mapped[str] = mapped_column(String(16), default="view", nullable=False)

    granted_at: Mapped[datetime] = _now()
    granted_by: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))
    expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_by: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True))

    __table_args__ = (
        CheckConstraint("role IN ('owner','self','viewer','editor','clinician')",
                        name="ck_membership_role"),
        CheckConstraint("scope IN ('view','view_targets','full')", name="ck_membership_scope"),
        # One live grant per (profile, account). Revoked rows are kept for the
        # audit trail, so uniqueness only applies while revoked_at IS NULL.
        Index("uq_membership_live", "profile_id", "account_id",
              unique=True, postgresql_where=revoked_at.is_(None)),
    )


# ──────────────────────────────────────────────────────────────────────
# Health data — everything below keys on profile_id
# ──────────────────────────────────────────────────────────────────────

class HealthProfile(Base):
    """Clinical attributes, 1:1 with Profile.

    Columns mirror ml/contracts/feature_spec.json v1.0.0 EXACTLY. If the
    contract changes, this table and the Flutter wizard change with it — that
    is the point of freezing it first.
    """

    __tablename__ = "health_profiles"

    profile_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"), primary_key=True
    )

    dob: Mapped[date | None] = mapped_column(Date)
    sex_at_birth: Mapped[str | None] = mapped_column(String(8))
    height_cm: Mapped[float | None] = mapped_column(Float)
    weight_kg: Mapped[float | None] = mapped_column(Float)
    waist_cm: Mapped[float | None] = mapped_column(Float)

    family_history: Mapped[str | None] = mapped_column(String(16))
    physical_activity: Mapped[str | None] = mapped_column(String(16))
    smoker: Mapped[bool | None] = mapped_column(Boolean)
    gestational_diabetes_history: Mapped[bool | None] = mapped_column(Boolean)

    # Collected and scored by FINDRISC/ADA, but NOT fed to the model.
    # See docs/leakage_audit.md — the model that used them was 0.18 AUC worse
    # on never-screened users, who are the target user.
    known_high_bp: Mapped[bool | None] = mapped_column(Boolean)
    on_bp_meds: Mapped[bool | None] = mapped_column(Boolean)
    history_high_glucose: Mapped[bool | None] = mapped_column(Boolean)

    diabetes_status: Mapped[str | None] = mapped_column(String(16))
    conditions: Mapped[list[str]] = mapped_column(ARRAY(Text), default=list, nullable=False)
    allergies: Mapped[list[str]] = mapped_column(ARRAY(Text), default=list, nullable=False)
    dietary_prefs: Mapped[list[str]] = mapped_column(ARRAY(Text), default=list, nullable=False)

    goal_type: Mapped[str | None] = mapped_column(String(16))
    goal_weight_kg: Mapped[float | None] = mapped_column(Float)

    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )

    profile: Mapped[Profile] = relationship(back_populates="health")

    __table_args__ = (
        CheckConstraint("sex_at_birth IS NULL OR sex_at_birth IN ('male','female')",
                        name="ck_sex_at_birth"),
        CheckConstraint(
            "family_history IS NULL OR family_history IN ('none','second_degree','first_degree')",
            name="ck_family_history"),
        CheckConstraint(
            "physical_activity IS NULL OR physical_activity IN "
            "('sedentary','light','moderate','active','very_active')",
            name="ck_physical_activity"),
        CheckConstraint(
            "diabetes_status IS NULL OR diabetes_status IN "
            "('no','prediabetes','t2d','t1d','gestational')",
            name="ck_diabetes_status"),
        # Ranges mirror feature_spec.json. Enforced here so a buggy migration
        # or a direct SQL write cannot store a physiologically impossible value.
        CheckConstraint("height_cm IS NULL OR (height_cm BETWEEN 100 AND 250)",
                        name="ck_height_range"),
        CheckConstraint("weight_kg IS NULL OR (weight_kg BETWEEN 25 AND 300)",
                        name="ck_weight_range"),
        CheckConstraint("waist_cm IS NULL OR (waist_cm BETWEEN 40 AND 200)",
                        name="ck_waist_range"),
    )


class RiskAssessment(Base):
    """One risk result. Every prediction stores its model_version (PRD §7.4)."""

    __tablename__ = "risk_assessments"

    id: Mapped[uuid.UUID] = _pk()
    profile_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"), nullable=False, index=True
    )
    taken_at: Mapped[datetime] = _now()
    tier: Mapped[int] = mapped_column(Integer, default=1, nullable=False)

    inputs_json: Mapped[dict] = mapped_column(JSONB, nullable=False)
    risk_probability: Mapped[float] = mapped_column(Float, nullable=False)
    risk_band: Mapped[str] = mapped_column(String(16), nullable=False)
    confidence_low: Mapped[float] = mapped_column(Float, nullable=False)
    confidence_high: Mapped[float] = mapped_column(Float, nullable=False)
    top_factors_json: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)

    region: Mapped[str] = mapped_column(String(2), nullable=False)
    validation_status: Mapped[str] = mapped_column(String(16), nullable=False)
    clinical_score: Mapped[str] = mapped_column(String(16), nullable=False)
    clinical_points: Mapped[int] = mapped_column(Integer, nullable=False)
    model_version: Mapped[str] = mapped_column(String(64), nullable=False)

    __table_args__ = (
        CheckConstraint("tier IN (1,2)", name="ck_risk_tier"),
        CheckConstraint("risk_probability BETWEEN 0 AND 1", name="ck_risk_probability"),
        CheckConstraint("confidence_low <= risk_probability AND risk_probability <= confidence_high",
                        name="ck_risk_range_contains_estimate"),
        CheckConstraint("risk_band IN ('low','moderate','high','very_high')", name="ck_risk_band"),
        Index("ix_risk_profile_taken", "profile_id", "taken_at"),
    )


class VitalLog(Base):
    """User-entered vitals. NEVER derived from device sensors (PRD §2.2)."""

    __tablename__ = "vital_logs"

    id: Mapped[uuid.UUID] = _pk()
    profile_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"), nullable=False, index=True
    )
    recorded_at: Mapped[datetime] = _now()
    type: Mapped[str] = mapped_column(String(16), nullable=False)
    value: Mapped[float] = mapped_column(Float, nullable=False)
    unit: Mapped[str] = mapped_column(String(16), nullable=False)
    context_tag: Mapped[str | None] = mapped_column(String(24))
    note: Mapped[str | None] = mapped_column(Text)

    __table_args__ = (
        CheckConstraint("type IN ('glucose','hba1c','weight','waist','bp_systolic','bp_diastolic')",
                        name="ck_vital_type"),
        Index("ix_vital_profile_time", "profile_id", "type", "recorded_at"),
    )


class AccessAuditLog(Base):
    """Every read or write on a profile the caller does not own.

    Patient-visible by default (PRD §3.6): "Dr. Rahman viewed your glucose log
    on 12 Aug." Append-only — the RLS policy grants INSERT and SELECT, never
    UPDATE or DELETE, so an audit trail cannot be quietly rewritten.
    """

    __tablename__ = "access_audit_log"

    id: Mapped[uuid.UUID] = _pk()
    profile_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"), nullable=False, index=True
    )
    actor_account_id: Mapped[uuid.UUID | None] = mapped_column(UUID(as_uuid=True), index=True)
    actor_role: Mapped[str] = mapped_column(String(16), nullable=False)
    action: Mapped[str] = mapped_column(String(32), nullable=False)
    resource: Mapped[str] = mapped_column(String(64), nullable=False)
    ip_hash: Mapped[str | None] = mapped_column(String(64))
    occurred_at: Mapped[datetime] = _now()
    visible_to_patient: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)

    __table_args__ = (Index("ix_audit_profile_time", "profile_id", "occurred_at"),)


class SafetyEvent(Base):
    """A red-flag interception (PRD §3.3).

    Recorded so the false-negative rate on the golden set can be measured —
    PRD §14 sets a target of zero, and you cannot hit a target you do not count.
    """

    __tablename__ = "safety_events"

    id: Mapped[uuid.UUID] = _pk()
    profile_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"), nullable=False, index=True
    )
    occurred_at: Mapped[datetime] = _now()
    trigger: Mapped[str] = mapped_column(String(48), nullable=False)
    severity: Mapped[str] = mapped_column(String(16), nullable=False)
    source_endpoint: Mapped[str] = mapped_column(String(64), nullable=False)
    payload_json: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)
    acknowledged_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        CheckConstraint("severity IN ('info','warning','urgent','emergency')",
                        name="ck_safety_severity"),
    )


# Every table carrying health data. rls.sql enables row-level security on each,
# and a test asserts this list matches what the database actually reports — so
# adding a table without a policy fails CI rather than leaking in production.
PROFILE_SCOPED_TABLES = [
    "profiles",
    "profile_memberships",
    "health_profiles",
    "risk_assessments",
    "vital_logs",
    "access_audit_log",
    "safety_events",
]
