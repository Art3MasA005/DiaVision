"""Request and response shapes.

The health-profile fields mirror ml/contracts/feature_spec.json v1.0.0. They
are written out explicitly rather than generated, because FastAPI needs them at
import time for the OpenAPI schema — but a test asserts the two stay in step,
so drift fails CI rather than shipping.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime
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


# ── food and meals ────────────────────────────────────────────────────

MealSlot = Literal["breakfast", "lunch", "snack", "dinner", "sehri", "iftar"]


class FoodOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name_en: str
    name_local: str | None
    kcal_per_100g: float
    carbs_g_per_100g: float
    protein_g_per_100g: float
    fat_g_per_100g: float
    fibre_g_per_100g: float
    glycemic_index: float | None
    portion_grams: dict[str, float]
    # 'placeholder' means the value is a widely-published approximation, not a
    # licensed composition table. The UI must not present it as authoritative.
    source: str


class MealItemIn(BaseModel):
    """One confirmed item. The user always confirms — the AI only proposes."""

    food_id: uuid.UUID | None = None
    name: str = Field(min_length=1, max_length=160)
    quantity: float = Field(default=1, gt=0, le=100)
    unit: str = Field(default="serving", max_length=24)
    # Supplied only when the client already knows the weight. Otherwise the
    # server converts from the local unit using the food's own portion table.
    grams: float | None = Field(default=None, gt=0, le=5000)
    recognition_confidence: float | None = Field(default=None, ge=0, le=1)


class MealItemOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name_snapshot: str
    quantity: float
    unit: str
    grams: float
    kcal: float
    carbs_g: float
    protein_g: float
    fat_g: float
    fibre_g: float
    glycemic_load: float | None
    recognition_confidence: float | None


class MealIn(BaseModel):
    profile_id: uuid.UUID
    slot: MealSlot
    items: list[MealItemIn] = Field(min_length=1, max_length=40)
    eaten_at: datetime | None = None
    note: str | None = Field(default=None, max_length=2000)
    entry_method: Literal["manual", "photo"] = "manual"


class MealOut(BaseModel):
    id: uuid.UUID
    slot: str
    eaten_at: datetime
    eaten_on: date
    entry_method: str
    note: str | None
    items: list[MealItemOut]
    kcal: float
    carbs_g: float
    protein_g: float
    fat_g: float
    fibre_g: float
    glycemic_load: float | None
    # Calories are always shown as a range with an "estimate" label — a photo
    # of a plate of rice is not known to the calorie.
    kcal_low: int
    kcal_high: int


class DayTotals(BaseModel):
    kcal: float
    carbs_g: float
    protein_g: float
    fat_g: float
    fibre_g: float
    glycemic_load: float | None
    kcal_low: int
    kcal_high: int


class TargetOut(BaseModel):
    kcal: int
    carbs_g: int
    protein_g: int
    fat_g: int
    fibre_g: int
    glycemic_load_ceiling: int
    maintenance_kcal: int
    # True when the §5.4 rails moved the number. Surfaced so the UI can explain
    # itself rather than silently showing a different figure than was asked for.
    was_clamped: bool
    clamp_reason: str | None
    weight_loss_disabled: bool
    notes: list[str]


class PlanTodayOut(BaseModel):
    """What the tracker screen needs in one call."""

    # Named `day` rather than `date` so the field does not shadow the type it
    # is annotated with.
    day: date
    target: TargetOut | None
    totals: DayTotals
    meals: list[MealOut]
    # Present when the day's pattern tripped a §5.4 rail, e.g. repeated very
    # low intake. Never gamified, never a failure state.
    safety_card: SafetyCardOut | None = None


class RecognizedItem(BaseModel):
    name: str
    confidence: float
    suggested_quantity: float
    suggested_unit: str
    food_id: uuid.UUID | None = None


class RecognizeOut(BaseModel):
    """Proposals only. Nothing is saved until the user confirms."""

    items: list[RecognizedItem]
    # False in this build — there is no recognition model wired. The client
    # must say so rather than implying a photo was understood.
    model_available: bool
    message: str
    confidence_floor: float


# ── check-ins ─────────────────────────────────────────────────────────

class CheckinIn(BaseModel):
    profile_id: uuid.UUID
    energy: int | None = Field(default=None, ge=1, le=5)
    sleep_hours: float | None = Field(default=None, ge=0, le=24)
    mood: int | None = Field(default=None, ge=1, le=5)
    symptoms: list[str] = Field(default_factory=list, max_length=20)
    note: str | None = Field(default=None, max_length=2000)
    checkin_on: date | None = None


class CheckinOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    checkin_on: date
    energy: int | None
    sleep_hours: float | None
    mood: int | None
    symptoms: list[str]
    note: str | None
    updated_at: datetime


# ── activity ──────────────────────────────────────────────────────────

class ActivityIn(BaseModel):
    profile_id: uuid.UUID
    activity_on: date | None = None
    steps: int = Field(default=0, ge=0, le=200_000)
    active_minutes: int = Field(default=0, ge=0, le=1440)
    distance_km: float | None = Field(default=None, ge=0, le=500)
    source: Literal["manual", "healthkit", "health_connect"] = "manual"


class ActivityOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    activity_on: date
    steps: int
    active_minutes: int
    distance_km: float | None
    source: str
    updated_at: datetime


# ── coach ─────────────────────────────────────────────────────────────

class CoachIn(BaseModel):
    profile_id: uuid.UUID
    message: str = Field(min_length=1, max_length=2000)


class CoachOut(BaseModel):
    reply: str
    # True when a guard answered instead of the responder — a red flag,
    # a medication question, or the diagnosis question.
    intercepted: bool
    # What the answer was built from. An answer the user cannot check is an
    # assertion, not an answer.
    cited: list[str]
    questions_remaining: int | None
    safety_card: SafetyCardOut | None = None
    # There is no language model behind this build. Stated in the payload so a
    # client cannot quietly present it as one.
    model_backed: bool = False


class CoachTurn(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    role: str
    body: str
    intercepted: bool
    created_at: datetime


# ── insights and reports ──────────────────────────────────────────────

class InsightOut(BaseModel):
    key: str
    headline: str
    detail: str
    observations: int
    direction: str


class WeeklyInsightsOut(BaseModel):
    period_start: date
    period_end: date
    insights: list[InsightOut]
    insufficient_data: bool
    minimum_observations: int


class ReportIn(BaseModel):
    profile_id: uuid.UUID
    days: int = Field(default=28, ge=7, le=180)


class ReportOut(BaseModel):
    id: uuid.UUID
    generated_at: datetime
    period_start: date
    period_end: date
    payload: dict


# ── billing ───────────────────────────────────────────────────────────

class PlanOut(BaseModel):
    code: str
    name: str
    price_minor: int
    currency: str
    period: str
    trial_days: int
    rails: list[str]


class PlansOut(BaseModel):
    plans: list[PlanOut]
    # Never gated, on any tier. Listed in the payload so the paywall screen
    # cannot accidentally imply otherwise.
    #
    # `free_forever_keys` is what a client should render from — the server
    # decides what is free, the client owns the wording in the user's language.
    # `free_forever` carries the English as a fallback for an older client that
    # meets a key it does not know.
    free_forever: list[str]
    free_forever_keys: list[str] = []
    current_status: str


class SubscribeIn(BaseModel):
    plan_code: str


# ── account preferences ───────────────────────────────────────────────

class PreferencesIn(BaseModel):
    locale: str | None = Field(default=None, max_length=8)
    units_prefs: dict | None = None


class ExportOut(BaseModel):
    """Everything this account holds. Free on every tier — a legal requirement,
    not a feature."""

    generated_at: datetime
    account: dict
    profiles: list[dict]
    consents: list[dict]
    health_profiles: list[dict]
    risk_assessments: list[dict]
    vitals: list[dict]
    meals: list[dict]
    checkins: list[dict]
    activity: list[dict]
