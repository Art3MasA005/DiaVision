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

    created_at: Mapped[datetime] = _now()
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    # Tokens issued before this instant are refused. Set by a password reset,
    # which is how "a successful reset signs out every other session" works
    # with stateless JWTs: nothing has to be listed, only compared.
    tokens_valid_after: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    owned_profiles: Mapped[list["Profile"]] = relationship(
        back_populates="owner", foreign_keys="Profile.account_id_owner"
    )

    __table_args__ = (
        CheckConstraint("account_type IN ('individual','family','clinic')",
                        name="ck_account_type"),
        CheckConstraint("subscription_status IN ('free','trial','active','past_due','cancelled')",
                        name="ck_subscription_status"),
    )


class Consent(Base):
    """One recorded agreement. Terms and the medical disclaimer are SEPARATE.

    Bundling them was the earlier mistake — a single `disclaimer_accepted_at`
    column could not answer "which version did they agree to, and when?", and
    it conflated two agreements a user makes at different moments for different
    reasons. Terms are accepted at signup; the medical disclaimer is its own
    blocking screen afterwards (PRD §3.2), and no health question may render
    before it is recorded.

    Rows are append-only: withdrawing consent writes a new row rather than
    editing the old one, so the history stays intact.
    """

    __tablename__ = "consents"

    id: Mapped[uuid.UUID] = _pk()
    account_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("accounts.id", ondelete="CASCADE"), nullable=False, index=True
    )
    kind: Mapped[str] = mapped_column(String(32), nullable=False)
    version: Mapped[str] = mapped_column(String(16), nullable=False)
    locale: Mapped[str] = mapped_column(String(8), nullable=False, default="en")
    accepted_at: Mapped[datetime] = _now()
    withdrawn_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    ip_hash: Mapped[str | None] = mapped_column(String(64))

    __table_args__ = (
        CheckConstraint("kind IN ('terms','privacy','medical_disclaimer','model_improvement')",
                        name="ck_consent_kind"),
        Index("ix_consent_account_kind", "account_id", "kind", "accepted_at"),
    )


class PasswordReset(Base):
    """One emailed reset code. Account-scoped, behind RLS like `consents`.

    The code itself is never stored, only an HMAC of it keyed with the server
    secret and the row id, so a database dump does not hand anyone a working
    code. Rules (handoff, screen "forgot"):

      * the code expires 10 minutes after it is sent;
      * 5 wrong tries lock reset for 30 minutes;
      * a new code is sent at most once every 60 seconds;
      * a successful reset stamps `accounts.tokens_valid_after`, which signs
        out every session that existed before it.
    """

    __tablename__ = "password_resets"

    id: Mapped[uuid.UUID] = _pk()
    account_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("accounts.id", ondelete="CASCADE"), nullable=False
    )
    code_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[datetime] = _now()
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    attempts: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    locked_until: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    verified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        CheckConstraint("attempts BETWEEN 0 AND 100", name="ck_reset_attempts"),
        Index("ix_password_resets_account_created", "account_id", "created_at"),
    )


# Bump when the wording changes. A user who agreed to v1 has NOT agreed to v2,
# and GET /consents/current is what surfaces that.
CONSENT_VERSIONS = {
    "terms": "1.0",
    "medical_disclaimer": "1.0",
}


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
    # Denormalised from profiles.account_id_owner, and load-bearing rather
    # than an optimisation. RLS policies must not form a cycle: if the
    # membership policy had to look up profiles to find the owner, and the
    # profiles policy looks up memberships, neither could ever resolve.
    # Carrying the owner here lets the membership policies read their own
    # columns only, which terminates. Kept in step by a trigger.
    owner_account_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), nullable=False, index=True
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
    # The user's own daily calorie goal from the tracker's goal sheet. A
    # request, not a target: it still goes through the §5.4 rails, so a goal
    # typed too low is raised to the floor rather than obeyed.
    kcal_goal: Mapped[int | None] = mapped_column(Integer)

    # Optional, user-declared: WHICH POPULATION'S PUBLISHED CUTOFFS to use.
    # Not an ethnicity model feature: it is applied at the calibration layer
    # (ml/pipelines/clinical_scores.py ANCESTRY_SCORE) and never reaches the
    # gradient booster. Special-category data under GDPR Art. 9, so NULL is
    # the default and costs the user nothing.
    ancestry_cutoff_group: Mapped[str | None] = mapped_column(String(24))

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
        CheckConstraint(
            "ancestry_cutoff_group IS NULL OR ancestry_cutoff_group IN "
            "('south_asian','east_asian','european','african','middle_eastern','hispanic')",
            name="ck_ancestry_cutoff_group"),
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


# Lab values live here rather than on HealthProfile, because they are
# observations with a date, not attributes of a person. A risk assessment reads
# the most recent one inside this window — an HbA1c from three years ago says
# nothing useful about today, and silently treating it as current would be
# worse than having no lab at all.
LAB_LOOKBACK_DAYS = 365


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


# ──────────────────────────────────────────────────────────────────────
# Food and meals — PRD §F3, §F4
# ──────────────────────────────────────────────────────────────────────

class FoodItem(Base):
    """A food in the composition table. REFERENCE DATA — not profile-scoped.

    Deliberately carries its own provenance. `packs/bd.json` records the
    Bangladesh food composition table as `permission_pending`, so nothing from
    that source is in here: the seeded rows are widely-published approximate
    values marked `source='placeholder'`, and the API reports that honestly
    rather than implying a licensed database exists.

    Per-100g, always. Portion conversion happens at the meal-item level, where
    the local unit is known — a বাটি of ভাত is not a বাটি of ডাল.
    """

    __tablename__ = "food_items"

    id: Mapped[uuid.UUID] = _pk()
    region: Mapped[str] = mapped_column(String(2), default="bd", nullable=False, index=True)

    name_en: Mapped[str] = mapped_column(String(160), nullable=False)
    name_local: Mapped[str | None] = mapped_column(String(160))

    kcal_per_100g: Mapped[float] = mapped_column(Float, nullable=False)
    carbs_g_per_100g: Mapped[float] = mapped_column(Float, default=0, nullable=False)
    protein_g_per_100g: Mapped[float] = mapped_column(Float, default=0, nullable=False)
    fat_g_per_100g: Mapped[float] = mapped_column(Float, default=0, nullable=False)
    fibre_g_per_100g: Mapped[float] = mapped_column(Float, default=0, nullable=False)

    # Glycemic index, 0–110. Null means unknown, and glycemic load is then not
    # computed rather than guessed — a fabricated GL is worse than no GL.
    glycemic_index: Mapped[float | None] = mapped_column(Float)

    # Grams for one of the region's local portion units, keyed by unit_en.
    portion_grams: Mapped[dict] = mapped_column(JSONB, default=dict, nullable=False)

    # Other names people type: transliterations ("bhat", "murgir jhol") and
    # common spellings. Lower-case, space-separated; searched with ILIKE.
    aliases: Mapped[str] = mapped_column(Text, default="", server_default="", nullable=False)

    source: Mapped[str] = mapped_column(String(32), default="placeholder", nullable=False)
    created_at: Mapped[datetime] = _now()

    __table_args__ = (
        CheckConstraint("kcal_per_100g BETWEEN 0 AND 900", name="ck_food_kcal"),
        CheckConstraint("glycemic_index IS NULL OR glycemic_index BETWEEN 0 AND 110",
                        name="ck_food_gi"),
        CheckConstraint("source IN ('placeholder','licensed','user')", name="ck_food_source"),
        Index("ix_food_region_name", "region", "name_en"),
    )


class MealLog(Base):
    """One eating occasion. Slots come from the region pack, never hard-coded."""

    __tablename__ = "meal_logs"

    id: Mapped[uuid.UUID] = _pk()
    profile_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"),
        nullable=False, index=True
    )
    eaten_at: Mapped[datetime] = _now()
    # Stored separately from eaten_at so a day's totals do not shift when the
    # user travels across a timezone.
    eaten_on: Mapped[date] = mapped_column(Date, nullable=False, index=True)
    slot: Mapped[str] = mapped_column(String(16), nullable=False)

    note: Mapped[str | None] = mapped_column(Text)

    # 'manual' | 'photo'. Photo means the items were PROPOSED by recognition
    # and then confirmed by the user — the human always disposes (PRD §F3).
    entry_method: Mapped[str] = mapped_column(String(16), default="manual", nullable=False)

    created_at: Mapped[datetime] = _now()

    items: Mapped[list["MealLogItem"]] = relationship(
        back_populates="meal", cascade="all, delete-orphan"
    )

    __table_args__ = (
        CheckConstraint("entry_method IN ('manual','photo')", name="ck_meal_entry_method"),
        Index("ix_meal_profile_day", "profile_id", "eaten_on"),
    )


class MealLogItem(Base):
    """One food in one meal, with the portion the user actually confirmed.

    Nutrition is denormalised onto the row at save time. A food's composition
    row may later be corrected, and a past meal must not silently change its
    calories underneath the user.
    """

    __tablename__ = "meal_log_items"

    id: Mapped[uuid.UUID] = _pk()
    meal_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("meal_logs.id", ondelete="CASCADE"),
        nullable=False, index=True
    )
    # Denormalised so RLS can filter items without joining meal_logs, which
    # would make the item policy depend on the meal policy.
    profile_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"),
        nullable=False, index=True
    )
    food_id: Mapped[uuid.UUID | None] = mapped_column(
        UUID(as_uuid=True), ForeignKey("food_items.id", ondelete="SET NULL")
    )

    name_snapshot: Mapped[str] = mapped_column(String(160), nullable=False)
    quantity: Mapped[float] = mapped_column(Float, default=1, nullable=False)
    unit: Mapped[str] = mapped_column(String(24), default="serving", nullable=False)
    grams: Mapped[float] = mapped_column(Float, nullable=False)

    kcal: Mapped[float] = mapped_column(Float, nullable=False)
    carbs_g: Mapped[float] = mapped_column(Float, default=0, nullable=False)
    protein_g: Mapped[float] = mapped_column(Float, default=0, nullable=False)
    fat_g: Mapped[float] = mapped_column(Float, default=0, nullable=False)
    fibre_g: Mapped[float] = mapped_column(Float, default=0, nullable=False)
    glycemic_load: Mapped[float | None] = mapped_column(Float)

    # 0–1 when the item came from photo recognition. Null for manual entry.
    # Below the confidence floor the client must make the user type the portion.
    recognition_confidence: Mapped[float | None] = mapped_column(Float)

    meal: Mapped[MealLog] = relationship(back_populates="items")

    __table_args__ = (
        CheckConstraint("grams > 0 AND grams <= 5000", name="ck_item_grams"),
        CheckConstraint("recognition_confidence IS NULL OR "
                        "recognition_confidence BETWEEN 0 AND 1",
                        name="ck_item_confidence"),
    )


# ──────────────────────────────────────────────────────────────────────
# Check-ins and activity — PRD §F6, §F14
# ──────────────────────────────────────────────────────────────────────

class DailyCheckin(Base):
    """The ≤30-second daily check-in (PRD §F14.1).

    One row per profile per day; submitting again updates it, because a
    check-in is a statement about a day rather than an event in it.
    """

    __tablename__ = "daily_checkins"

    id: Mapped[uuid.UUID] = _pk()
    profile_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"),
        nullable=False, index=True
    )
    checkin_on: Mapped[date] = mapped_column(Date, nullable=False)

    energy: Mapped[int | None] = mapped_column(Integer)
    sleep_hours: Mapped[float | None] = mapped_column(Float)
    mood: Mapped[int | None] = mapped_column(Integer)

    # Free-form list; the interceptor reads it. Kept as text rather than an
    # enum so a region pack can add locally-worded symptoms without a migration.
    symptoms: Mapped[list[str]] = mapped_column(ARRAY(Text), default=list, nullable=False)
    note: Mapped[str | None] = mapped_column(Text)

    created_at: Mapped[datetime] = _now()
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )

    __table_args__ = (
        CheckConstraint("energy IS NULL OR energy BETWEEN 1 AND 5", name="ck_checkin_energy"),
        CheckConstraint("mood IS NULL OR mood BETWEEN 1 AND 5", name="ck_checkin_mood"),
        CheckConstraint("sleep_hours IS NULL OR sleep_hours BETWEEN 0 AND 24",
                        name="ck_checkin_sleep"),
        UniqueConstraint("profile_id", "checkin_on", name="uq_checkin_profile_day"),
    )


class ActivityLog(Base):
    """Steps and active minutes for one day.

    Upserted per day rather than appended: a health platform reports a running
    total, and appending would count the same steps repeatedly.
    """

    __tablename__ = "activity_logs"

    id: Mapped[uuid.UUID] = _pk()
    profile_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"),
        nullable=False, index=True
    )
    activity_on: Mapped[date] = mapped_column(Date, nullable=False)

    steps: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    active_minutes: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    distance_km: Mapped[float | None] = mapped_column(Float)

    # 'manual' | 'healthkit' | 'health_connect'. Recorded because a reconciled
    # platform figure and a typed one deserve different trust.
    source: Mapped[str] = mapped_column(String(24), default="manual", nullable=False)

    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )

    __table_args__ = (
        CheckConstraint("steps BETWEEN 0 AND 200000", name="ck_activity_steps"),
        CheckConstraint("active_minutes BETWEEN 0 AND 1440", name="ck_activity_minutes"),
        UniqueConstraint("profile_id", "activity_on", name="uq_activity_profile_day"),
    )


class WaterLog(Base):
    """Glasses of water for one day. Upserted per day, like activity."""

    __tablename__ = "water_logs"

    id: Mapped[uuid.UUID] = _pk()
    profile_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"),
        nullable=False, index=True
    )
    logged_on: Mapped[date] = mapped_column(Date, nullable=False)
    glasses: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    ml_per_glass: Mapped[int] = mapped_column(Integer, default=250, nullable=False)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False
    )

    __table_args__ = (
        CheckConstraint("glasses BETWEEN 0 AND 30", name="ck_water_glasses"),
        CheckConstraint("ml_per_glass BETWEEN 50 AND 1000", name="ck_water_ml"),
        UniqueConstraint("profile_id", "logged_on", name="uq_water_profile_day"),
    )


class FoodFavourite(Base):
    """A food the user starred in Add food. Profile-scoped, behind RLS."""

    __tablename__ = "food_favourites"

    id: Mapped[uuid.UUID] = _pk()
    profile_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"),
        nullable=False, index=True
    )
    food_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("food_items.id", ondelete="CASCADE"), nullable=False
    )
    created_at: Mapped[datetime] = _now()

    __table_args__ = (
        UniqueConstraint("profile_id", "food_id", name="uq_favourite_profile_food"),
    )


# ──────────────────────────────────────────────────────────────────────
# Coach and reports — PRD §F8, §F9, §F10
# ──────────────────────────────────────────────────────────────────────

class CoachMessage(Base):
    """One turn of the guarded coach thread.

    Stored so the free-tier daily cap can be counted and so a safety
    interception is auditable. `intercepted` marks a turn the red-flag checker
    answered instead of the responder.
    """

    __tablename__ = "coach_messages"

    id: Mapped[uuid.UUID] = _pk()
    profile_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"),
        nullable=False, index=True
    )
    created_at: Mapped[datetime] = _now()
    role: Mapped[str] = mapped_column(String(12), nullable=False)
    body: Mapped[str] = mapped_column(Text, nullable=False)
    intercepted: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)

    __table_args__ = (
        CheckConstraint("role IN ('user','coach')", name="ck_coach_role"),
        Index("ix_coach_profile_time", "profile_id", "created_at"),
    )


class Report(Base):
    """A generated clinician-facing summary (PRD §F9).

    The payload is stored rather than regenerated on read, so the thing a
    patient handed their doctor last week still says what it said last week.
    """

    __tablename__ = "reports"

    id: Mapped[uuid.UUID] = _pk()
    profile_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("profiles.id", ondelete="CASCADE"),
        nullable=False, index=True
    )
    generated_at: Mapped[datetime] = _now()
    period_start: Mapped[date] = mapped_column(Date, nullable=False)
    period_end: Mapped[date] = mapped_column(Date, nullable=False)
    payload_json: Mapped[dict] = mapped_column(JSONB, nullable=False)

    # Share links expire (PRD §F9). Null means never shared.
    share_expires_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        CheckConstraint("period_end >= period_start", name="ck_report_period"),
        Index("ix_report_profile_time", "profile_id", "generated_at"),
    )


# Free-tier coach questions per day (PRD §F10, §F16). Premium removes the cap.
COACH_FREE_DAILY_LIMIT = 3

# Below this, photo recognition must not pre-fill a portion — the user types it.
RECOGNITION_CONFIDENCE_FLOOR = 0.55


# Every table carrying health data. rls.sql enables row-level security on each,
# and a test asserts this list matches what the database actually reports — so
# adding a table without a policy fails CI rather than leaking in production.
#
# `food_items` is deliberately absent: it is reference data with no profile
# column, readable by everyone and writable by nobody through the API.
PROFILE_SCOPED_TABLES = [
    "profiles",
    "profile_memberships",
    "health_profiles",
    "risk_assessments",
    "vital_logs",
    "access_audit_log",
    "safety_events",
    "meal_logs",
    "meal_log_items",
    "daily_checkins",
    "activity_logs",
    "coach_messages",
    "reports",
    "water_logs",
    "food_favourites",
]
