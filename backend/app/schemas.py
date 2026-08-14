"""Request and response shapes.

The health-profile fields mirror ml/contracts/feature_spec.json v1.0.0. They
are written out explicitly rather than generated, because FastAPI needs them at
import time for the OpenAPI schema — but a test asserts the two stay in step,
so drift fails CI rather than shipping.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, EmailStr, Field

Sex = Literal["male", "female"]
FamilyHistory = Literal["none", "second_degree", "first_degree"]
Activity = Literal["sedentary", "light", "moderate", "active", "very_active"]
DiabetesStatus = Literal["no", "prediabetes", "t2d", "t1d", "gestational"]


# ── auth ──────────────────────────────────────────────────────────────

class SignupRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=8, max_length=72)
    display_name: str = Field(min_length=1, max_length=120)
    region: str = Field(default="bd", pattern="^[a-z]{2}$")
    locale: str = Field(default="bn", max_length=8)
    accept_terms: bool = Field(
        description="Terms and Privacy Policy. SEPARATE from the medical disclaimer, "
                    "which is its own blocking screen afterwards and its own consent record."
    )


class LoginRequest(BaseModel):
    email: EmailStr
    password: str


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int


class RefreshRequest(BaseModel):
    refresh_token: str


# ── profiles ──────────────────────────────────────────────────────────

class ProfileOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    display_name: str
    avatar_color: str
    profile_type: str
    region_pack: str
    is_managed: bool
    created_at: datetime


class AccountOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    email: EmailStr
    home_region: str
    data_residency_zone: str
    locale: str
    subscription_status: str


# ── consent ───────────────────────────────────────────────────────────

ConsentKind = Literal["terms", "privacy", "medical_disclaimer", "model_improvement"]


class ConsentIn(BaseModel):
    kind: ConsentKind
    version: str | None = Field(
        default=None,
        description="Omit to accept the current version. Supply one only to record "
                    "agreement to a specific historical wording.",
    )
    locale: str = "en"


class ConsentOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    kind: str
    version: str
    locale: str
    accepted_at: datetime
    withdrawn_at: datetime | None


class ConsentStatus(BaseModel):
    """What this account has agreed to, and what is still outstanding."""

    accepted: dict[str, str]
    outstanding: list[str]
    current_versions: dict[str, str]
    may_answer_health_questions: bool


# ── health profile ────────────────────────────────────────────────────

class HealthProfileIn(BaseModel):
    """Mirrors feature_spec.json v1.0.0. Ranges match the DB CHECK constraints."""

    sex_at_birth: Sex
    height_cm: float = Field(ge=100, le=250)
    weight_kg: float = Field(ge=25, le=300)
    waist_cm: float | None = Field(default=None, ge=40, le=200)

    family_history: FamilyHistory = "none"
    physical_activity: Activity = "sedentary"
    smoker: bool = False
    gestational_diabetes_history: bool | None = None

    # Collected and scored by FINDRISC/ADA, but NOT fed to the model.
    # See docs/leakage_audit.md.
    known_high_bp: bool = False
    on_bp_meds: bool = False
    history_high_glucose: bool = False

    diabetes_status: DiabetesStatus = "no"
    conditions: list[str] = Field(default_factory=list)
    pregnant: bool = False

    # Age is supplied directly rather than derived from a date of birth, so the
    # under-18 gate (PRD §3.3) can run before any health data is stored.
    age_years: int = Field(ge=1, le=120)


class HealthProfileOut(HealthProfileIn):
    model_config = ConfigDict(from_attributes=True)
    profile_id: uuid.UUID
    updated_at: datetime


# ── risk ──────────────────────────────────────────────────────────────

class FactorOut(BaseModel):
    label: str
    points: int
    modifiable: bool
    detail: str = ""


class RiskAssessRequest(BaseModel):
    """PRD §10: every health request carries an explicit profile_id.

    Never inferred from the session — the server verifies the caller's grant.
    """

    profile_id: uuid.UUID
    region: str | None = Field(default=None, pattern="^[a-z]{2}$")


class LabFindingOut(BaseModel):
    test: str
    value: float
    display: str
    band: str
    statement: str


class LabValuesIn(BaseModel):
    """Optional Tier 2 entry. Both fields optional — at least one required.

    Values are stored as dated observations, not profile attributes, so a
    stale result is never silently treated as current.
    """

    profile_id: uuid.UUID
    hba1c_percent: float | None = Field(default=None, ge=3.0, le=20.0)
    fasting_glucose_mmol_l: float | None = Field(default=None, ge=1.0, le=40.0)
    taken_on: datetime | None = Field(
        default=None, description="When the blood was drawn. Defaults to now."
    )


class RiskResultOut(BaseModel):
    id: uuid.UUID | None = None
    band: str
    band_label: str
    probability: float
    range_low: float
    range_high: float
    tier: int
    basis: str
    validation_status: str
    region: str
    model_version: str
    clinical_score: str
    clinical_points: int
    clinical_max: int
    modifiable_factors: list[FactorOut]
    fixed_factors: list[FactorOut]
    caveats: list[str]
    disclaimer: str
    taken_at: datetime | None = None

    # Tier 2. Present only when a recent lab value was found; when present
    # these carry the headline, because a measurement outranks an estimate.
    lab_findings: list[LabFindingOut] = []
    lab_statement: str | None = None


class RiskHistoryItem(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    taken_at: datetime
    risk_probability: float
    risk_band: str
    confidence_low: float
    confidence_high: float
    model_version: str
    validation_status: str


# ── vitals ────────────────────────────────────────────────────────────

VitalType = Literal["glucose", "hba1c", "weight", "waist", "bp_systolic", "bp_diastolic"]


class VitalIn(BaseModel):
    profile_id: uuid.UUID
    type: VitalType
    value: float
    unit: str
    context_tag: str | None = None
    note: str | None = Field(default=None, max_length=2000)


class VitalOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    type: str
    value: float
    unit: str
    context_tag: str | None
    recorded_at: datetime


# ── safety ────────────────────────────────────────────────────────────

class SafetyCardOut(BaseModel):
    """Replaces the normal response when a red flag fires (PRD §3.3)."""

    trigger: str
    severity: str
    title: str
    body: str
    actions: list[str]
    emergency_number: str | None = None
