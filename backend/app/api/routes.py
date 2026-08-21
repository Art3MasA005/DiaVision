"""API routes — PRD §10, the vertical slice.

Two cross-cutting rules apply to every health endpoint here:

  resolveProfile     every health request carries an explicit `profile_id` and
                     the server verifies the caller's grant. NEVER inferred
                     from the session (PRD §10).
  redFlagInterceptor runs on /vitals before anything is stored (PRD §3.3).

Access control itself is enforced by row-level security in the database, so a
missing filter here returns nothing rather than someone else's data.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime, timedelta, timezone

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import func, select, text
from sqlalchemy.dialects.postgresql import insert as pg_insert
from sqlalchemy.orm import Session

from app import schemas
from app.auth import (
    create_access_token, create_refresh_token, current_account_id, decode_token,
    hash_password, verify_password,
)
from app.config import get_settings
from app.db.models import (
    Account, AccessAuditLog, ActivityLog, COACH_FREE_DAILY_LIMIT, CoachMessage,
    Consent, CONSENT_VERSIONS, DailyCheckin, FoodItem, HealthProfile,
    LAB_LOOKBACK_DAYS, MealLog, MealLogItem, Profile, ProfileMembership,
    RECOGNITION_CONFIDENCE_FLOOR, Report, RiskAssessment, SafetyEvent, VitalLog,
)
from app.db.session import SessionLocal, set_actor
from app.safety import (
    SafetyCard, Severity, check_disordered_eating, check_glucose, check_profile,
    check_text,
)
from app.services import coach as coach_service
from app.services import insights as insights_service
from app.services import nutrition
from app.services import risk as risk_service

settings = get_settings()
router = APIRouter()


# ── dependencies ──────────────────────────────────────────────────────

def db_session(account_id: uuid.UUID = Depends(current_account_id)):
    """An authenticated, actor-scoped transaction.

    `set_actor` issues SET LOCAL app.account_id, which every RLS policy reads.
    """
    session = SessionLocal()
    try:
        set_actor(session, account_id)
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()


def anonymous_session():
    """For signup and login only — no actor is known yet."""
    session = SessionLocal()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()


def resolve_profile(session: Session, profile_id: uuid.UUID) -> Profile:
    """Fetch a profile the caller is allowed to see.

    RLS does the real work: an unauthorised profile simply is not visible, so
    this returns 404 rather than 403 — telling an attacker that a profile
    exists but is not theirs is itself a small leak.
    """
    profile = session.get(Profile, profile_id)
    if profile is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Profile not found")
    return profile


def require_medical_disclaimer(session: Session, account_id: uuid.UUID) -> None:
    """No health question may render before the disclaimer is accepted (PRD §3.2).

    Enforced here as well as in the UI. A client that skips the screen — an old
    build, a scripted request — must still be refused.
    """
    current = CONSENT_VERSIONS["medical_disclaimer"]
    accepted = session.scalar(
        select(Consent).where(
            Consent.account_id == account_id,
            Consent.kind == "medical_disclaimer",
            Consent.version == current,
            Consent.withdrawn_at.is_(None),
        ).limit(1)
    )
    if accepted is None:
        raise HTTPException(status.HTTP_403_FORBIDDEN, {
            "reason": "medical_disclaimer_required",
            "required_version": current,
            "message": ("The medical disclaimer must be accepted before any health "
                        "information is collected or returned."),
        })


def latest_labs(session: Session, profile_id: uuid.UUID) -> dict[str, float]:
    """Most recent lab values inside the lookback window.

    Outside the window they are ignored entirely rather than aged into the
    estimate — a three-year-old HbA1c is not weak evidence about today, it is
    no evidence, and treating it as current would be worse than having none.
    """
    cutoff = datetime.now(timezone.utc) - timedelta(days=LAB_LOOKBACK_DAYS)
    out: dict[str, float] = {}
    for vital_type, field in (("hba1c", "hba1c_percent"), ("glucose", "fasting_glucose_mmol_l")):
        row = session.scalar(
            select(VitalLog).where(
                VitalLog.profile_id == profile_id,
                VitalLog.type == vital_type,
                VitalLog.recorded_at >= cutoff,
                # Only a FASTING reading is comparable to the diagnostic
                # threshold; a random glucose means something different.
                *([VitalLog.context_tag == "fasting"] if vital_type == "glucose" else []),
            ).order_by(VitalLog.recorded_at.desc()).limit(1)
        )
        if row is not None:
            value = row.value / 18.0 if row.unit.lower() in ("mg/dl", "mgdl") else row.value
            out[field] = float(value)
    return out


def commit_before_responding(session: Session) -> None:
    """Make a write visible before the response goes out.

    FastAPI closes the dependency exit stack AFTER the response has been sent,
    so `db_session`'s commit lands a moment too late: a client that saves and
    immediately re-reads can miss its own write. The app does exactly that —
    save a meal, pop back to the tracker, reload — and the meal would be
    missing until the next refresh.

    **Call this only when nothing else in the request will query.** `set_actor`
    uses a transaction-local `SET LOCAL`, so committing clears the actor and
    any query after this point would be denied by RLS and silently see
    nothing. In practice that means: build the response object first, commit,
    return.
    """
    session.commit()


def raise_safety_card(session: Session, card, *, emergency_number: str | None,
                      recorded: bool = True) -> None:
    """Commit what was recorded, THEN raise the safety card.

    This exists because of a bug worth naming. `db_session` rolls back on any
    exception, and an HTTPException raised from a route is an exception — so
    the 409 that carries `"recorded": true` was undoing the very row it claimed
    to have stored. A user logged a dangerous glucose reading, was told it had
    been saved, and nothing was saved.

    Committing first is the whole fix. The dependency's later rollback then
    applies to a fresh, empty transaction and does nothing.

    PRD §3.3 is explicit that the reading is kept: refusing to store it would
    lose clinical history at exactly the moment it matters most.
    """
    if recorded:
        session.commit()
    raise HTTPException(status.HTTP_409_CONFLICT, {
        "safety_card": {
            "trigger": card.trigger, "severity": card.severity.value,
            "title": card.title, "body": card.body, "actions": card.actions,
            "emergency_number": emergency_number,
        },
        "recorded": recorded,
    })


def audit(session: Session, profile: Profile, actor: uuid.UUID,
          action: str, resource: str, request: Request | None = None) -> None:
    """Record access to a profile the caller does not own (PRD §3.6)."""
    if profile.account_id_owner == actor or profile.claimed_by_account_id == actor:
        return
    ip_hash = None
    if request and request.client:
        import hashlib
        ip_hash = hashlib.sha256(request.client.host.encode()).hexdigest()[:64]
    session.add(AccessAuditLog(
        profile_id=profile.id, actor_account_id=actor, actor_role="viewer",
        action=action, resource=resource, ip_hash=ip_hash, visible_to_patient=True,
    ))


# ── auth ──────────────────────────────────────────────────────────────

@router.post("/auth/signup", response_model=schemas.TokenResponse,
             status_code=status.HTTP_201_CREATED, tags=["auth"])
def signup(body: schemas.SignupRequest, session: Session = Depends(anonymous_session)):
    if not body.accept_terms:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            "The Terms and Privacy Policy must be accepted to create an account.")

    # Uses the same privileged lookup as login: a plain SELECT here would be
    # filtered to nothing by RLS (no actor yet), so every duplicate would fall
    # through to the unique constraint and surface as a 500 instead of a 409.
    existing = session.execute(
        text("SELECT account_id FROM app_lookup_account_for_auth(:email)"),
        {"email": body.email},
    ).one_or_none()
    if existing:
        raise HTTPException(status.HTTP_409_CONFLICT, "An account with that email already exists")

    try:
        pack = risk_service.region_pack(body.region)
    except FileNotFoundError:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"Unsupported region {body.region!r}")

    # The id is generated here rather than by the database so the actor can be
    # declared BEFORE the insert. RLS on `accounts` requires
    # id = app_current_account(), and at signup there is no prior actor to
    # inherit — this is the bootstrap.
    account_id = uuid.uuid4()
    set_actor(session, account_id)

    account = Account(
        id=account_id,
        email=body.email,
        password_hash=hash_password(body.password),
        home_region=body.region,
        data_residency_zone=pack["data_residency_zone"],
        locale=body.locale,
    )
    session.add(account)
    session.flush()

    # Terms only. The medical disclaimer is a separate agreement made on its
    # own blocking screen, and bundling them here would misrepresent what the
    # user actually agreed to.
    session.add(Consent(
        account_id=account_id, kind="terms",
        version=CONSENT_VERSIONS["terms"], locale=body.locale,
    ))

    profile = Profile(
        account_id_owner=account.id, claimed_by_account_id=account.id,
        display_name=body.display_name, profile_type="self", region_pack=body.region,
    )
    session.add(profile)
    session.flush()
    session.add(ProfileMembership(
        profile_id=profile.id, account_id=account.id, role="owner", scope="full",
        granted_by=account.id,
    ))

    out = schemas.TokenResponse(
        access_token=create_access_token(account.id),
        refresh_token=create_refresh_token(account.id),
        expires_in=settings.access_token_minutes * 60,
    )
    # The client uses these tokens immediately. Handing out credentials for an
    # account that is not committed yet means the very next request — GET
    # /profiles — can find nothing.
    commit_before_responding(session)
    return out


@router.post("/auth/login", response_model=schemas.TokenResponse, tags=["auth"])
def login(body: schemas.LoginRequest, session: Session = Depends(anonymous_session)):
    # RLS on `accounts` keys on app.account_id, which we do not know yet — we
    # have only an email. app_lookup_account_for_auth is the one narrow
    # SECURITY DEFINER exception, returning id, hash and deleted_at for a
    # single email and nothing more. See backend/scripts/setup_db.py.
    row = session.execute(
        text("SELECT account_id, password_hash, deleted_at "
             "FROM app_lookup_account_for_auth(:email)"),
        {"email": body.email},
    ).one_or_none()

    # Same message either way, and the hash is verified even when no account
    # exists, so response timing does not reveal whether an email is registered.
    if row is None:
        verify_password(body.password, _DUMMY_HASH)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Incorrect email or password")

    account_id, password_hash, deleted_at = row
    if not verify_password(body.password, password_hash) or deleted_at is not None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Incorrect email or password")

    return schemas.TokenResponse(
        access_token=create_access_token(account_id),
        refresh_token=create_refresh_token(account_id),
        expires_in=settings.access_token_minutes * 60,
    )


# Compared against when no account matches, so a failed lookup costs the same
# time as a failed password. Computed once at import.
_DUMMY_HASH = hash_password("bye-bye-diabetes-timing-equaliser")


@router.post("/auth/refresh", response_model=schemas.TokenResponse, tags=["auth"])
def refresh(body: schemas.RefreshRequest):
    payload = decode_token(body.refresh_token, expect="refresh")
    account_id = payload["sub"]
    return schemas.TokenResponse(
        access_token=create_access_token(account_id),
        refresh_token=create_refresh_token(account_id),
        expires_in=settings.access_token_minutes * 60,
    )


@router.get("/me", response_model=schemas.AccountOut, tags=["auth"])
def me(account_id: uuid.UUID = Depends(current_account_id),
       session: Session = Depends(db_session)):
    account = session.get(Account, account_id)
    if account is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Account not found")
    return account


# ── consent ───────────────────────────────────────────────────────────

@router.post("/consents", response_model=schemas.ConsentOut,
             status_code=status.HTTP_201_CREATED, tags=["consent"])
def record_consent(body: schemas.ConsentIn, request: Request,
                   account_id: uuid.UUID = Depends(current_account_id),
                   session: Session = Depends(db_session)):
    """Record an agreement. Append-only — a re-accept writes a new row."""
    version = body.version or CONSENT_VERSIONS.get(body.kind, "1.0")
    ip_hash = None
    if request.client:
        import hashlib
        ip_hash = hashlib.sha256(request.client.host.encode()).hexdigest()[:64]

    row = Consent(account_id=account_id, kind=body.kind, version=version,
                  locale=body.locale, ip_hash=ip_hash)
    session.add(row)
    session.flush()

    # The disclaimer screen records this and then re-reads
    # /consents/current to decide whether the wizard may open. Committing
    # late made `may_answer_health_questions` come back false for the user who
    # had just accepted it.
    out = schemas.ConsentOut.model_validate(row)
    commit_before_responding(session)
    return out


@router.get("/consents/current", response_model=schemas.ConsentStatus, tags=["consent"])
def consent_status(account_id: uuid.UUID = Depends(current_account_id),
                   session: Session = Depends(db_session)):
    """What has been agreed, and what still blocks the health flow."""
    rows = session.scalars(
        select(Consent).where(
            Consent.account_id == account_id, Consent.withdrawn_at.is_(None)
        ).order_by(Consent.accepted_at.desc())
    ).all()

    accepted: dict[str, str] = {}
    for row in rows:
        accepted.setdefault(row.kind, row.version)

    outstanding = [
        kind for kind, current in CONSENT_VERSIONS.items()
        if accepted.get(kind) != current
    ]
    return schemas.ConsentStatus(
        accepted=accepted,
        outstanding=outstanding,
        current_versions=dict(CONSENT_VERSIONS),
        may_answer_health_questions="medical_disclaimer" not in outstanding,
    )


# ── profiles ──────────────────────────────────────────────────────────

@router.get("/profiles", response_model=list[schemas.ProfileOut], tags=["profiles"])
def list_profiles(session: Session = Depends(db_session)):
    """Everything this account may access. RLS decides what that is."""
    return list(session.scalars(select(Profile).order_by(Profile.created_at)))


@router.put("/profiles/{profile_id}/health", response_model=schemas.HealthProfileOut,
            tags=["profiles"])
def upsert_health_profile(
    profile_id: uuid.UUID, body: schemas.HealthProfileIn, request: Request,
    account_id: uuid.UUID = Depends(current_account_id),
    session: Session = Depends(db_session),
):
    require_medical_disclaimer(session, account_id)
    profile = resolve_profile(session, profile_id)

    # Profile-level gates run BEFORE any health data is stored (PRD §3.3).
    card = check_profile(age=body.age_years, pregnant=body.pregnant,
                         conditions=body.conditions)
    if card is not None and card.blocks_response:
        session.add(SafetyEvent(
            profile_id=profile.id, trigger=card.trigger, severity=card.severity.value,
            source_endpoint="PUT /profiles/{id}/health",
            payload_json={"age_years": body.age_years},
        ))
        # Commit the safety event before raising, or the rollback in
        # `db_session` erases it — and PRD §14 measures the false-negative rate
        # from these rows, which cannot be done if they vanish.
        session.commit()
        raise HTTPException(status.HTTP_403_FORBIDDEN, {
            "safety_card": {
                "trigger": card.trigger, "severity": card.severity.value,
                "title": card.title, "body": card.body, "actions": card.actions,
            }
        })

    health = session.get(HealthProfile, profile_id)
    if health is None:
        health = HealthProfile(profile_id=profile_id)
        session.add(health)

    for field in ("sex_at_birth", "height_cm", "weight_kg", "waist_cm",
                  "family_history", "physical_activity", "smoker",
                  "gestational_diabetes_history", "known_high_bp", "on_bp_meds",
                  "history_high_glucose", "diabetes_status", "conditions"):
        setattr(health, field, getattr(body, field))

    # The wizard asks for age, but the record stores a date of birth so the
    # value ages correctly instead of going stale the moment it is saved.
    # The day is approximate — we never display it, only difference it.
    health.dob = _dob_from_age(body.age_years)

    audit(session, profile, account_id, "write", "health_profile", request)
    session.flush()

    out = schemas.HealthProfileOut(
        profile_id=profile_id, updated_at=health.updated_at or datetime.now(timezone.utc),
        age_years=body.age_years, pregnant=body.pregnant,
        **body.model_dump(exclude={"age_years", "pregnant"}),
    )
    # The wizard submits this and asks for an assessment straight afterwards;
    # without the early commit that request finds no health row and 400s.
    commit_before_responding(session)
    return out


# ── risk ──────────────────────────────────────────────────────────────

@router.post("/risk/assess", response_model=schemas.RiskResultOut, tags=["risk"])
def assess_risk(
    body: schemas.RiskAssessRequest, request: Request,
    account_id: uuid.UUID = Depends(current_account_id),
    session: Session = Depends(db_session),
):
    require_medical_disclaimer(session, account_id)
    profile = resolve_profile(session, body.profile_id)
    health = session.get(HealthProfile, profile.id)
    if health is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            "Complete the health profile before requesting a risk estimate")

    if risk_service.should_route_to_management(health.diabetes_status):
        # PRD §F1 — diabetes_status routes the whole experience. Someone already
        # diagnosed does not need an estimate of whether they might be.
        raise HTTPException(status.HTTP_409_CONFLICT, {
            "reason": "already_diagnosed",
            "message": ("This profile reports an existing diagnosis, so a screening "
                        "estimate does not apply. Use management mode instead."),
        })

    record = risk_service.health_profile_to_record(health)
    # Tier 2: fold in any recent lab value. These are read against published
    # thresholds, never fed to the model — see docs/leakage_audit.md.
    record.update(latest_labs(session, profile.id))
    region = body.region or profile.region_pack

    try:
        result = risk_service.assess(record, region)
    except ValueError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, str(exc)) from exc
    except FileNotFoundError as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, str(exc)) from exc

    row = RiskAssessment(
        profile_id=profile.id, tier=result["tier"], inputs_json=record,
        risk_probability=result["probability"],
        risk_band=result["band"],
        confidence_low=result["range_low"], confidence_high=result["range_high"],
        top_factors_json={"modifiable": result["modifiable_factors"],
                          "fixed": result["fixed_factors"]},
        region=result["region"], validation_status=result["validation_status"],
        clinical_score=result["clinical_score"], clinical_points=result["clinical_points"],
        model_version=result["model_version"],
    )
    session.add(row)
    audit(session, profile, account_id, "read", "risk_assessment", request)
    session.flush()

    return schemas.RiskResultOut(id=row.id, taken_at=row.taken_at, **result)


@router.get("/risk/history", response_model=list[schemas.RiskHistoryItem], tags=["risk"])
def risk_history(profile_id: uuid.UUID, session: Session = Depends(db_session)):
    resolve_profile(session, profile_id)
    return list(session.scalars(
        select(RiskAssessment)
        .where(RiskAssessment.profile_id == profile_id)
        .order_by(RiskAssessment.taken_at.desc())
        .limit(100)
    ))


def _dob_from_age(age_years: int) -> date:
    """Today's date, `age_years` back. Feb 29 falls back to Feb 28."""
    today = date.today()
    try:
        return today.replace(year=today.year - age_years)
    except ValueError:
        return today.replace(year=today.year - age_years, day=28)


# ── vitals ────────────────────────────────────────────────────────────

@router.post("/vitals", response_model=schemas.VitalOut,
             status_code=status.HTTP_201_CREATED, tags=["vitals"])
def add_vital(
    body: schemas.VitalIn, request: Request,
    account_id: uuid.UUID = Depends(current_account_id),
    session: Session = Depends(db_session),
):
    profile = resolve_profile(session, body.profile_id)

    # Red-flag interceptor — runs BEFORE the value is stored (PRD §3.3).
    card = None
    if body.type == "glucose":
        value = body.value / 18.0 if body.unit.lower() in ("mg/dl", "mgdl") else body.value
        pack = risk_service.region_pack(profile.region_pack)
        card = check_glucose(value, body.context_tag,
                             pack.get("safety_thresholds", {}).get("glucose_mmol_l"))

    row = VitalLog(
        profile_id=profile.id, type=body.type, value=body.value, unit=body.unit,
        context_tag=body.context_tag, note=body.note,
    )
    session.add(row)

    if card is not None:
        session.add(SafetyEvent(
            profile_id=profile.id, trigger=card.trigger, severity=card.severity.value,
            source_endpoint="POST /vitals",
            payload_json={"type": body.type, "value": body.value, "unit": body.unit},
        ))

    audit(session, profile, account_id, "write", "vital_log", request)
    session.flush()

    # The reading is still recorded — refusing to store it would lose clinical
    # history — but the safety card replaces the normal response.
    if card is not None and card.blocks_response:
        pack = risk_service.region_pack(profile.region_pack)
        raise_safety_card(
            session, card,
            emergency_number=pack.get("safety_thresholds", {})
            .get("emergency_number"),
        )

    out = schemas.VitalOut.model_validate(row)
    commit_before_responding(session)
    return out


@router.post("/labs", response_model=list[schemas.VitalOut],
             status_code=status.HTTP_201_CREATED, tags=["vitals"])
def add_labs(
    body: schemas.LabValuesIn, request: Request,
    account_id: uuid.UUID = Depends(current_account_id),
    session: Session = Depends(db_session),
):
    """Tier 2 lab entry from the user's own report (PRD §F2).

    Convenience over /vitals: accepts the two values the risk screen asks for
    in one call, and stores them as dated observations so a stale result is
    never mistaken for a current one.
    """
    require_medical_disclaimer(session, account_id)
    profile = resolve_profile(session, body.profile_id)

    if body.hba1c_percent is None and body.fasting_glucose_mmol_l is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            "Provide an HbA1c or a fasting glucose value.")

    recorded_at = body.taken_on or datetime.now(timezone.utc)
    rows: list[VitalLog] = []

    if body.hba1c_percent is not None:
        rows.append(VitalLog(profile_id=profile.id, type="hba1c",
                             value=body.hba1c_percent, unit="%",
                             recorded_at=recorded_at))

    card = None
    if body.fasting_glucose_mmol_l is not None:
        pack = risk_service.region_pack(profile.region_pack)
        card = check_glucose(body.fasting_glucose_mmol_l, "fasting",
                             pack.get("safety_thresholds", {}).get("glucose_mmol_l"))
        rows.append(VitalLog(profile_id=profile.id, type="glucose",
                             value=body.fasting_glucose_mmol_l, unit="mmol/L",
                             context_tag="fasting", recorded_at=recorded_at))

    for row in rows:
        session.add(row)

    if card is not None:
        session.add(SafetyEvent(
            profile_id=profile.id, trigger=card.trigger, severity=card.severity.value,
            source_endpoint="POST /labs",
            payload_json={"fasting_glucose_mmol_l": body.fasting_glucose_mmol_l},
        ))

    audit(session, profile, account_id, "write", "labs", request)
    session.flush()

    if card is not None and card.blocks_response:
        pack = risk_service.region_pack(profile.region_pack)
        raise_safety_card(
            session, card,
            emergency_number=pack.get("safety_thresholds", {})
            .get("emergency_number"),
        )

    # The labs screen re-assesses immediately to show the narrowed range, and
    # a Tier 2 result depends on this row being visible.
    out = [schemas.VitalOut.model_validate(r) for r in rows]
    commit_before_responding(session)
    return out


# ── regions ───────────────────────────────────────────────────────────

@router.get("/regions/{code}/pack", tags=["regions"])
def get_region_pack(code: str):
    try:
        return risk_service.region_pack(code)
    except FileNotFoundError as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, str(exc)) from exc


@router.get("/regions/{code}/validation", tags=["regions"])
def get_validation_status(code: str):
    """PRD §7.4b — every market declares its status honestly."""
    try:
        pack = risk_service.region_pack(code)
    except FileNotFoundError as exc:
        raise HTTPException(status.HTTP_404_NOT_FOUND, str(exc)) from exc
    model = pack["risk_model"]
    return {
        "region": code,
        "validation_status": model["validation_status"],
        "clinical_score": model["clinical_score"],
        "core_model_version": model.get("core_model_version"),
        "methodology_url": "/docs/model_card.md",
    }


# ── vitals, read side ─────────────────────────────────────────────────

@router.get("/vitals", response_model=list[schemas.VitalOut], tags=["vitals"])
def list_vitals(
    profile_id: uuid.UUID,
    type: schemas.VitalType | None = None,
    days: int = 30,
    session: Session = Depends(db_session),
):
    """Readings back out. The write side has existed since the vertical slice;
    without this the glucose screen could record history it could never show."""
    resolve_profile(session, profile_id)
    cutoff = datetime.now(timezone.utc) - timedelta(days=max(1, min(days, 730)))
    query = select(VitalLog).where(
        VitalLog.profile_id == profile_id, VitalLog.recorded_at >= cutoff
    )
    if type is not None:
        query = query.where(VitalLog.type == type)
    return list(session.scalars(query.order_by(VitalLog.recorded_at.desc()).limit(500)))


# ── food and meals ────────────────────────────────────────────────────

@router.get("/foods", response_model=list[schemas.FoodOut], tags=["food"])
def search_foods(q: str = "", region: str = "bd", limit: int = 40,
                 session: Session = Depends(db_session)):
    """The composition table.

    Rows seeded as `source='placeholder'` are widely-published approximations,
    NOT the Bangladesh food composition table — `packs/bd.json` records that
    source as `permission_pending`. The field is returned so the client can say
    so rather than implying a licensed database.
    """
    query = select(FoodItem).where(FoodItem.region == region)
    if q.strip():
        query = query.where(FoodItem.name_en.ilike(f"%{q.strip()}%"))
    return list(session.scalars(query.order_by(FoodItem.name_en).limit(min(limit, 100))))


def _build_items(session: Session, profile_id: uuid.UUID, meal_id: uuid.UUID,
                 items: list[schemas.MealItemIn]) -> list[MealLogItem]:
    """Turn confirmed portions into stored rows.

    Nutrition is computed here and written onto the row, not looked up on read:
    a composition value may later be corrected, and a meal the user logged last
    month must not silently change its calories underneath them.
    """
    out: list[MealLogItem] = []
    for item in items:
        food_row = session.get(FoodItem, item.food_id) if item.food_id else None
        food = {
            "kcal_per_100g": getattr(food_row, "kcal_per_100g", 0.0),
            "carbs_g_per_100g": getattr(food_row, "carbs_g_per_100g", 0.0),
            "protein_g_per_100g": getattr(food_row, "protein_g_per_100g", 0.0),
            "fat_g_per_100g": getattr(food_row, "fat_g_per_100g", 0.0),
            "fibre_g_per_100g": getattr(food_row, "fibre_g_per_100g", 0.0),
            "glycemic_index": getattr(food_row, "glycemic_index", None),
        }
        grams = item.grams or nutrition.grams_for(
            item.quantity, item.unit, getattr(food_row, "portion_grams", None)
        )
        n = nutrition.nutrients_for(grams, food).rounded()
        out.append(MealLogItem(
            meal_id=meal_id, profile_id=profile_id, food_id=item.food_id,
            name_snapshot=item.name, quantity=item.quantity, unit=item.unit,
            grams=round(grams, 1), kcal=n.kcal, carbs_g=n.carbs_g,
            protein_g=n.protein_g, fat_g=n.fat_g, fibre_g=n.fibre_g,
            glycemic_load=n.glycemic_load,
            recognition_confidence=item.recognition_confidence,
        ))
    return out


def _meal_out(meal: MealLog) -> schemas.MealOut:
    total = nutrition.Nutrients()
    for item in meal.items:
        total = total + nutrition.Nutrients(
            kcal=item.kcal, carbs_g=item.carbs_g, protein_g=item.protein_g,
            fat_g=item.fat_g, fibre_g=item.fibre_g, glycemic_load=item.glycemic_load,
        )
    low, high = nutrition.estimate_band(total.kcal, meal.entry_method)
    return schemas.MealOut(
        id=meal.id, slot=meal.slot, eaten_at=meal.eaten_at, eaten_on=meal.eaten_on,
        entry_method=meal.entry_method, note=meal.note,
        items=[schemas.MealItemOut.model_validate(i) for i in meal.items],
        kcal=round(total.kcal), carbs_g=round(total.carbs_g, 1),
        protein_g=round(total.protein_g, 1), fat_g=round(total.fat_g, 1),
        fibre_g=round(total.fibre_g, 1),
        glycemic_load=None if total.glycemic_load is None else round(total.glycemic_load, 1),
        kcal_low=low, kcal_high=high,
    )


@router.post("/meals", response_model=schemas.MealOut,
             status_code=status.HTTP_201_CREATED, tags=["food"])
def log_meal(body: schemas.MealIn, request: Request,
             account_id: uuid.UUID = Depends(current_account_id),
             session: Session = Depends(db_session)):
    """Log a meal the user has confirmed.

    `entry_method='photo'` means recognition PROPOSED these items and a human
    accepted them. There is no path here that stores an unconfirmed item.
    """
    require_medical_disclaimer(session, account_id)
    profile = resolve_profile(session, body.profile_id)

    eaten_at = body.eaten_at or datetime.now(timezone.utc)
    meal = MealLog(
        profile_id=profile.id, slot=body.slot, eaten_at=eaten_at,
        eaten_on=eaten_at.date(), note=body.note, entry_method=body.entry_method,
    )
    session.add(meal)
    session.flush()

    for row in _build_items(session, profile.id, meal.id, body.items):
        session.add(row)
    session.flush()
    session.refresh(meal)

    audit(session, profile, account_id, "write", "meal_log", request)
    # Build the response while the actor is still set, then commit — the
    # tracker reloads the moment this returns.
    out = _meal_out(meal)
    commit_before_responding(session)
    return out


@router.get("/meals", response_model=list[schemas.MealOut], tags=["food"])
def list_meals(profile_id: uuid.UUID, on: date | None = None, days: int = 1,
               session: Session = Depends(db_session)):
    resolve_profile(session, profile_id)
    end = on or date.today()
    start = end - timedelta(days=max(1, min(days, 90)) - 1)
    rows = session.scalars(
        select(MealLog)
        .where(MealLog.profile_id == profile_id,
               MealLog.eaten_on >= start, MealLog.eaten_on <= end)
        .order_by(MealLog.eaten_at)
    ).all()
    return [_meal_out(m) for m in rows]


@router.delete("/meals/{meal_id}", status_code=status.HTTP_204_NO_CONTENT, tags=["food"])
def delete_meal(meal_id: uuid.UUID, session: Session = Depends(db_session)):
    meal = session.get(MealLog, meal_id)
    if meal is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Meal not found")
    session.delete(meal)


@router.post("/food/recognize", response_model=schemas.RecognizeOut, tags=["food"])
def recognize_food(profile_id: uuid.UUID,
                   account_id: uuid.UUID = Depends(current_account_id),
                   session: Session = Depends(db_session)):
    """Photo recognition.

    **No model is wired in this build**, and `packs/bd.json` ships
    `camera_food_logging: false`. Rather than return invented items — which on
    a food-and-blood-sugar screen would be actively harmful — this returns an
    empty proposal list and says plainly that recognition is unavailable, so
    the client falls back to manual entry.

    The endpoint exists now so the contract, the confidence floor and the
    confirm-before-save flow are settled before a model arrives.
    """
    require_medical_disclaimer(session, account_id)
    profile = resolve_profile(session, profile_id)
    pack = risk_service.region_pack(profile.region_pack)
    enabled = bool(pack.get("features", {}).get("camera_food_logging"))
    return schemas.RecognizeOut(
        items=[],
        model_available=False,
        message=("Photo recognition is not available yet — add the items by hand. "
                 "Every item is yours to confirm either way."
                 if enabled else
                 "Photo food logging is switched off for this region."),
        confidence_floor=RECOGNITION_CONFIDENCE_FLOOR,
    )


# ── the day's plan ────────────────────────────────────────────────────

def _target_for(session: Session, profile: Profile) -> schemas.TargetOut | None:
    """Today's targets, or None when the health profile is not complete enough.

    Guessing a calorie target from a partial profile would be worse than
    showing none — the §5.4 floors depend on sex and body size.
    """
    health = session.get(HealthProfile, profile.id)
    if health is None or not health.weight_kg or not health.height_cm or not health.dob:
        return None
    record = risk_service.health_profile_to_record(health)
    age = record.get("age_years") or 40
    bmi = nutrition.bmi_for(health.weight_kg, health.height_cm)
    target = nutrition.daily_target(
        sex=health.sex_at_birth or "female",
        weight_kg=health.weight_kg, height_cm=health.height_cm, age=age,
        activity=health.physical_activity or "sedentary",
        goal=health.goal_type or "maintain", bmi=bmi,
    )
    return schemas.TargetOut(
        kcal=target.kcal, carbs_g=target.carbs_g, protein_g=target.protein_g,
        fat_g=target.fat_g, fibre_g=target.fibre_g,
        glycemic_load_ceiling=target.glycemic_load_ceiling,
        maintenance_kcal=target.maintenance_kcal, was_clamped=target.was_clamped,
        clamp_reason=target.clamp_reason,
        weight_loss_disabled=target.weight_loss_disabled, notes=target.notes,
    )


@router.get("/plan/today", response_model=schemas.PlanTodayOut, tags=["food"])
def plan_today(profile_id: uuid.UUID, on: date | None = None,
               account_id: uuid.UUID = Depends(current_account_id),
               session: Session = Depends(db_session)):
    """Everything the tracker screen needs, in one round trip."""
    require_medical_disclaimer(session, account_id)
    profile = resolve_profile(session, profile_id)
    day = on or date.today()

    meals = session.scalars(
        select(MealLog).where(MealLog.profile_id == profile_id, MealLog.eaten_on == day)
        .order_by(MealLog.eaten_at)
    ).all()
    meal_outs = [_meal_out(m) for m in meals]

    totals = nutrition.Nutrients()
    for m in meal_outs:
        totals = totals + nutrition.Nutrients(
            kcal=m.kcal, carbs_g=m.carbs_g, protein_g=m.protein_g,
            fat_g=m.fat_g, fibre_g=m.fibre_g, glycemic_load=m.glycemic_load,
        )
    low, high = nutrition.estimate_band(totals.kcal)

    # The §5.4 restriction check, over the last fortnight. Never gamified and
    # never a failure state — it turns aggressive targets OFF.
    recent = session.execute(
        select(MealLog.eaten_on, func.sum(MealLogItem.kcal))
        .join(MealLogItem, MealLogItem.meal_id == MealLog.id)
        .where(MealLog.profile_id == profile_id,
               MealLog.eaten_on >= day - timedelta(days=14))
        .group_by(MealLog.eaten_on)
    ).all()
    card = check_disordered_eating([float(k or 0) for _, k in recent])

    return schemas.PlanTodayOut(
        day=day,
        target=_target_for(session, profile),
        totals=schemas.DayTotals(
            kcal=round(totals.kcal), carbs_g=round(totals.carbs_g, 1),
            protein_g=round(totals.protein_g, 1), fat_g=round(totals.fat_g, 1),
            fibre_g=round(totals.fibre_g, 1),
            glycemic_load=None if totals.glycemic_load is None
            else round(totals.glycemic_load, 1),
            kcal_low=low, kcal_high=high,
        ),
        meals=meal_outs,
        safety_card=None if card is None else schemas.SafetyCardOut(
            trigger=card.trigger, severity=card.severity.value, title=card.title,
            body=card.body, actions=card.actions,
        ),
    )


# ── check-ins ─────────────────────────────────────────────────────────

# Symptom combinations that route the check-in to a safety card instead of
# back to Home (PRD §3.3). Hard-coded, never model-decided.
SYMPTOM_CLUSTERS = {
    frozenset({"blurred_vision", "excessive_thirst"}),
    frozenset({"excessive_thirst", "frequent_urination"}),
    frozenset({"blurred_vision", "frequent_urination"}),
    frozenset({"numbness", "slow_healing"}),
}


@router.post("/checkins", response_model=schemas.CheckinOut,
             status_code=status.HTTP_201_CREATED, tags=["checkin"])
def submit_checkin(body: schemas.CheckinIn, request: Request,
                   account_id: uuid.UUID = Depends(current_account_id),
                   session: Session = Depends(db_session)):
    """One day's check-in. Re-submitting the same day updates it.

    The red-flag interceptor runs on every submission. A symptom cluster that
    crosses the threshold routes to the safety card rather than back to Home —
    and, as everywhere else, the check-in IS still recorded first.
    """
    require_medical_disclaimer(session, account_id)
    profile = resolve_profile(session, body.profile_id)
    day = body.checkin_on or date.today()

    symptoms = [s.strip().lower() for s in body.symptoms]

    # A real upsert, not SELECT-then-INSERT. This transaction cannot see a row
    # another in-flight request has inserted but not committed, so the read
    # would miss it, the insert would race, and the unique constraint on
    # (profile_id, checkin_on) would turn a double-tap into a 500. Let the
    # database resolve the conflict — it is the only thing that can.
    row = session.scalar(
        pg_insert(DailyCheckin)
        .values(
            id=uuid.uuid4(), profile_id=profile.id, checkin_on=day,
            energy=body.energy, sleep_hours=body.sleep_hours, mood=body.mood,
            symptoms=symptoms, note=body.note,
        )
        .on_conflict_do_update(
            constraint="uq_checkin_profile_day",
            set_={
                "energy": body.energy, "sleep_hours": body.sleep_hours,
                "mood": body.mood, "symptoms": symptoms, "note": body.note,
                "updated_at": func.now(),
            },
        )
        .returning(DailyCheckin)
    )

    audit(session, profile, account_id, "write", "daily_checkin", request)
    session.flush()

    # Free-text notes go through the same phrase interceptor the coach uses.
    card = check_text(body.note or "")
    if card is None:
        reported = set(row.symptoms)
        if any(cluster <= reported for cluster in SYMPTOM_CLUSTERS):
            # Warning, not urgent: this is "write it down and take it with you",
            # not "go to hospital". Styling it as an emergency would be wrong
            # and would teach the user to ignore the ones that are.
            card = SafetyCard(
                trigger="symptom_cluster",
                severity=Severity.WARNING,
                title="Worth showing a doctor",
                body=("Logged together, these are worth mentioning at your next "
                      "visit. Consider asking for a fasting glucose or HbA1c test. "
                      "This is not urgent — write it down and take it with you."),
                actions=["Add to my visit notes", "Find a doctor"],
            )

    if card is not None:
        session.add(SafetyEvent(
            profile_id=profile.id, trigger=card.trigger, severity=card.severity.value,
            source_endpoint="POST /checkins",
            payload_json={"symptoms": row.symptoms},
        ))
        session.flush()
        if card.blocks_response:
            pack = risk_service.region_pack(profile.region_pack)
            raise_safety_card(
                session, card,
                emergency_number=pack.get("safety_thresholds", {})
                .get("emergency_number"),
            )

    out = schemas.CheckinOut.model_validate(row)
    commit_before_responding(session)
    return out


@router.get("/checkins/today", response_model=schemas.CheckinOut | None, tags=["checkin"])
def checkin_today(profile_id: uuid.UUID, on: date | None = None,
                  session: Session = Depends(db_session)):
    resolve_profile(session, profile_id)
    return session.scalar(
        select(DailyCheckin).where(DailyCheckin.profile_id == profile_id,
                                   DailyCheckin.checkin_on == (on or date.today()))
    )


@router.get("/checkins", response_model=list[schemas.CheckinOut], tags=["checkin"])
def list_checkins(profile_id: uuid.UUID, days: int = 30,
                  session: Session = Depends(db_session)):
    resolve_profile(session, profile_id)
    start = date.today() - timedelta(days=max(1, min(days, 365)) - 1)
    return list(session.scalars(
        select(DailyCheckin)
        .where(DailyCheckin.profile_id == profile_id, DailyCheckin.checkin_on >= start)
        .order_by(DailyCheckin.checkin_on.desc())
    ))


# ── activity ──────────────────────────────────────────────────────────

@router.post("/activity", response_model=schemas.ActivityOut, tags=["activity"])
def upsert_activity(body: schemas.ActivityIn, request: Request,
                    account_id: uuid.UUID = Depends(current_account_id),
                    session: Session = Depends(db_session)):
    """Steps for a day. Upserted, not appended.

    A health platform reports a running daily total, so appending would count
    the same steps again on every sync.

    Done as a real INSERT ... ON CONFLICT rather than SELECT-then-INSERT. A
    SELECT cannot see a row another in-flight request has inserted but not yet
    committed, so two syncs arriving close together both decided to insert and
    the second hit `uq_activity_profile_day` — a 500 on the ordinary path,
    because a health platform syncs in bursts. The database is the only layer
    that can resolve that, so it does.
    """
    require_medical_disclaimer(session, account_id)
    profile = resolve_profile(session, body.profile_id)
    day = body.activity_on or date.today()

    row = session.scalar(
        pg_insert(ActivityLog)
        .values(
            id=uuid.uuid4(), profile_id=profile.id, activity_on=day,
            steps=body.steps, active_minutes=body.active_minutes,
            distance_km=body.distance_km, source=body.source,
        )
        .on_conflict_do_update(
            constraint="uq_activity_profile_day",
            set_={
                "steps": body.steps, "active_minutes": body.active_minutes,
                "distance_km": body.distance_km, "source": body.source,
                "updated_at": func.now(),
            },
        )
        .returning(ActivityLog)
    )

    audit(session, profile, account_id, "write", "activity_log", request)
    out = schemas.ActivityOut.model_validate(row)
    commit_before_responding(session)
    return out


@router.get("/activity", response_model=list[schemas.ActivityOut], tags=["activity"])
def list_activity(profile_id: uuid.UUID, days: int = 7,
                  session: Session = Depends(db_session)):
    resolve_profile(session, profile_id)
    start = date.today() - timedelta(days=max(1, min(days, 365)) - 1)
    return list(session.scalars(
        select(ActivityLog)
        .where(ActivityLog.profile_id == profile_id, ActivityLog.activity_on >= start)
        .order_by(ActivityLog.activity_on.desc())
    ))


# ── coach ─────────────────────────────────────────────────────────────

@router.post("/coach/message", response_model=schemas.CoachOut, tags=["coach"])
def coach_message(body: schemas.CoachIn, request: Request,
                  account_id: uuid.UUID = Depends(current_account_id),
                  session: Session = Depends(db_session)):
    """One coach turn.

    The red-flag interceptor runs BEFORE any responder sees the message, and a
    safety interception is never rate-limited — PRD §F16 forbids gating a
    safety message behind payment, and a daily cap is a gate.
    """
    require_medical_disclaimer(session, account_id)
    profile = resolve_profile(session, body.profile_id)
    account = session.get(Account, account_id)

    session.add(CoachMessage(profile_id=profile.id, role="user", body=body.message))

    # Safety first, and outside the cap.
    interception = coach_service.check_text(body.message)

    premium = (account is not None
               and account.subscription_status in ("trial", "active"))
    remaining: int | None = None
    if not premium:
        since = datetime.now(timezone.utc) - timedelta(days=1)
        used = session.scalar(
            select(func.count()).select_from(CoachMessage).where(
                CoachMessage.profile_id == profile.id,
                CoachMessage.role == "user",
                CoachMessage.intercepted.is_(False),
                CoachMessage.created_at >= since,
            )
        ) or 0
        remaining = max(0, COACH_FREE_DAILY_LIMIT - used)
        if remaining == 0 and interception is None:
            raise HTTPException(status.HTTP_402_PAYMENT_REQUIRED, {
                "reason": "coach_limit_reached",
                "message": (f"You've used today's {COACH_FREE_DAILY_LIMIT} free coach "
                            f"questions. Premium makes them unlimited."),
                "questions_remaining": 0,
            })

    context = _coach_context(session, profile.id)
    reply = coach_service.respond(body.message, context)

    session.add(CoachMessage(profile_id=profile.id, role="coach",
                             body=reply.body, intercepted=reply.intercepted))
    audit(session, profile, account_id, "write", "coach_message", request)

    if reply.safety_card is not None:
        session.add(SafetyEvent(
            profile_id=profile.id, trigger=reply.safety_card.trigger,
            severity=reply.safety_card.severity.value,
            source_endpoint="POST /coach/message", payload_json={},
        ))
    session.flush()

    pack = risk_service.region_pack(profile.region_pack)
    card = reply.safety_card
    return schemas.CoachOut(
        reply=reply.body,
        intercepted=reply.intercepted,
        cited=reply.cited,
        questions_remaining=None if premium else max(0, (remaining or 1) - 1),
        safety_card=None if card is None else schemas.SafetyCardOut(
            trigger=card.trigger, severity=card.severity.value, title=card.title,
            body=card.body, actions=card.actions,
            emergency_number=pack.get("safety_thresholds", {}).get("emergency_number"),
        ),
        model_backed=False,
    )


def _coach_context(session: Session, profile_id: uuid.UUID) -> dict:
    """Only this profile's own recent figures. Nothing is invented here."""
    since = date.today() - timedelta(days=14)
    kcal_rows = session.execute(
        select(MealLog.eaten_on, func.sum(MealLogItem.kcal))
        .join(MealLogItem, MealLogItem.meal_id == MealLog.id)
        .where(MealLog.profile_id == profile_id, MealLog.eaten_on >= since)
        .group_by(MealLog.eaten_on)
    ).all()
    steps = session.scalars(
        select(ActivityLog.steps).where(ActivityLog.profile_id == profile_id,
                                        ActivityLog.activity_on >= since)
    ).all()
    glucose = session.scalar(
        select(VitalLog).where(VitalLog.profile_id == profile_id,
                               VitalLog.type == "glucose")
        .order_by(VitalLog.recorded_at.desc()).limit(1)
    )
    risk = session.scalar(
        select(RiskAssessment).where(RiskAssessment.profile_id == profile_id)
        .order_by(RiskAssessment.taken_at.desc()).limit(1)
    )
    kcal = [float(k or 0) for _, k in kcal_rows if k]
    return {
        "mean_kcal": sum(kcal) / len(kcal) if kcal else None,
        "mean_steps": sum(steps) / len(steps) if steps else None,
        "latest_glucose": None if glucose is None else round(glucose.value, 1),
        "latest_risk_range": (
            None if risk is None
            else f"{round(risk.confidence_low * 100)}–{round(risk.confidence_high * 100)}%"
        ),
        "days_logged": len(kcal),
    }


@router.get("/coach/history", response_model=list[schemas.CoachTurn], tags=["coach"])
def coach_history(profile_id: uuid.UUID, limit: int = 50,
                  session: Session = Depends(db_session)):
    resolve_profile(session, profile_id)
    rows = list(session.scalars(
        select(CoachMessage).where(CoachMessage.profile_id == profile_id)
        .order_by(CoachMessage.created_at.desc()).limit(min(limit, 200))
    ))
    return list(reversed(rows))


# ── insights and reports ──────────────────────────────────────────────

def _daily_series(session: Session, profile_id: uuid.UUID, start: date, end: date):
    kcal_rows = session.execute(
        select(MealLog.eaten_on, func.sum(MealLogItem.kcal),
               func.sum(MealLogItem.glycemic_load))
        .join(MealLogItem, MealLogItem.meal_id == MealLog.id)
        .where(MealLog.profile_id == profile_id,
               MealLog.eaten_on >= start, MealLog.eaten_on <= end)
        .group_by(MealLog.eaten_on)
    ).all()
    daily_kcal = {d: float(k or 0) for d, k, _ in kcal_rows}
    daily_gl = {d: float(g or 0) for d, _, g in kcal_rows}
    daily_steps = {
        row.activity_on: row.steps for row in session.scalars(
            select(ActivityLog).where(ActivityLog.profile_id == profile_id,
                                      ActivityLog.activity_on >= start,
                                      ActivityLog.activity_on <= end)
        )
    }
    return daily_kcal, daily_gl, daily_steps


@router.get("/insights/weekly", response_model=schemas.WeeklyInsightsOut, tags=["insights"])
def weekly_insights(profile_id: uuid.UUID, days: int = 7,
                    account_id: uuid.UUID = Depends(current_account_id),
                    session: Session = Depends(db_session)):
    """Patterns in this person's own logs. Never causal, always evidenced."""
    require_medical_disclaimer(session, account_id)
    resolve_profile(session, profile_id)
    end = date.today()
    days = max(7, min(days, 90))
    start = end - timedelta(days=days - 1)

    daily_kcal, daily_gl, daily_steps = _daily_series(session, profile_id, start, end)
    checkins = [
        {"sleep_hours": c.sleep_hours, "energy": c.energy}
        for c in session.scalars(
            select(DailyCheckin).where(DailyCheckin.profile_id == profile_id,
                                       DailyCheckin.checkin_on >= start)
            .order_by(DailyCheckin.checkin_on)
        )
    ]
    glucose = [
        {"value": v.value, "context_tag": v.context_tag}
        for v in session.scalars(
            select(VitalLog).where(VitalLog.profile_id == profile_id,
                                   VitalLog.type == "glucose",
                                   VitalLog.recorded_at >= datetime.combine(
                                       start, datetime.min.time(), timezone.utc))
            .order_by(VitalLog.recorded_at)
        )
    ]

    result = insights_service.weekly_insights(
        period_end=end, daily_kcal=daily_kcal, daily_gl=daily_gl,
        daily_steps=daily_steps, checkins=checkins,
        glucose_readings=glucose, days=days,
    )
    return schemas.WeeklyInsightsOut(**result.to_dict())


@router.post("/reports/generate", response_model=schemas.ReportOut,
             status_code=status.HTTP_201_CREATED, tags=["insights"])
def generate_report(body: schemas.ReportIn, request: Request,
                    account_id: uuid.UUID = Depends(current_account_id),
                    session: Session = Depends(db_session)):
    """The artefact a patient hands a doctor.

    Stored rather than regenerated on read, so the report someone shared last
    week still says what it said last week.
    """
    require_medical_disclaimer(session, account_id)
    profile = resolve_profile(session, body.profile_id)
    end = date.today()
    start = end - timedelta(days=body.days - 1)

    daily_kcal, daily_gl, daily_steps = _daily_series(session, profile.id, start, end)
    health = session.get(HealthProfile, profile.id)
    record = risk_service.health_profile_to_record(health) if health else {}

    since = datetime.combine(start, datetime.min.time(), timezone.utc)
    glucose = [{"value": v.value} for v in session.scalars(
        select(VitalLog).where(VitalLog.profile_id == profile.id,
                               VitalLog.type == "glucose",
                               VitalLog.recorded_at >= since)
        .order_by(VitalLog.recorded_at))]
    weights = [{"value": v.value} for v in session.scalars(
        select(VitalLog).where(VitalLog.profile_id == profile.id,
                               VitalLog.type == "weight",
                               VitalLog.recorded_at >= since)
        .order_by(VitalLog.recorded_at))]

    risk_row = session.scalar(
        select(RiskAssessment).where(RiskAssessment.profile_id == profile.id)
        .order_by(RiskAssessment.taken_at.desc()).limit(1)
    )
    latest_risk = None if risk_row is None else {
        "range_low": risk_row.confidence_low, "range_high": risk_row.confidence_high,
        "band": risk_row.risk_band, "band_label": risk_row.risk_band.replace("_", " ").title(),
        "taken_at": risk_row.taken_at.isoformat(),
        "basis": risk_row.model_version, "clinical_score": risk_row.clinical_score,
        "clinical_points": risk_row.clinical_points, "clinical_max": 100,
        "validation_status": risk_row.validation_status,
    }

    insight_block = insights_service.weekly_insights(
        period_end=end, daily_kcal=daily_kcal, daily_gl=daily_gl,
        daily_steps=daily_steps, checkins=[], glucose_readings=glucose,
        days=body.days,
    )

    payload = insights_service.build_report(
        period_start=start, period_end=end, profile_name=profile.display_name,
        age=record.get("age_years"), sex=record.get("sex_at_birth"),
        latest_risk=latest_risk, daily_kcal=daily_kcal, daily_gl=daily_gl,
        daily_steps=daily_steps, glucose_readings=glucose,
        weight_readings=weights, insights=insight_block,
    )

    row = Report(profile_id=profile.id, period_start=start, period_end=end,
                 payload_json=payload,
                 share_expires_at=datetime.now(timezone.utc) + timedelta(days=7))
    session.add(row)
    audit(session, profile, account_id, "read", "report", request)
    session.flush()

    return schemas.ReportOut(
        id=row.id, generated_at=row.generated_at, period_start=start,
        period_end=end, payload=payload,
    )


@router.get("/reports/{report_id}", response_model=schemas.ReportOut, tags=["insights"])
def get_report(report_id: uuid.UUID, session: Session = Depends(db_session)):
    row = session.get(Report, report_id)
    if row is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Report not found")
    return schemas.ReportOut(
        id=row.id, generated_at=row.generated_at, period_start=row.period_start,
        period_end=row.period_end, payload=row.payload_json,
    )


# ── billing ───────────────────────────────────────────────────────────

# Prices in the minor unit (poisha). bKash and Nagad are the local rails.
PLANS = [
    {"code": "monthly", "name": "Monthly", "price_minor": 29900, "currency": "BDT",
     "period": "month", "trial_days": 14, "rails": ["bkash", "nagad", "card"]},
    {"code": "annual", "name": "Annual", "price_minor": 249900, "currency": "BDT",
     "period": "year", "trial_days": 14, "rails": ["bkash", "nagad", "card"]},
]

# Free on every tier, forever. Listed in the payload so the paywall screen
# cannot imply otherwise, and so a future change has to be deliberate.
#
# Sent as STABLE KEYS, not prose. The server decides *what* is free; the client
# owns the wording, because it knows the user's language and this backend does
# not carry a translation table. The English strings travel alongside as a
# fallback for a client that meets a key it was built before.
FREE_FOREVER = [
    ("risk_assessment", "Risk assessment"),
    ("meal_logging", "Meal logging"),
    ("safety_alerts", "Safety alerts"),
    ("data_export", "Export of your own data"),
]


@router.get("/billing/plans", response_model=schemas.PlansOut, tags=["billing"])
def billing_plans(account_id: uuid.UUID = Depends(current_account_id),
                  session: Session = Depends(db_session)):
    account = session.get(Account, account_id)
    return schemas.PlansOut(
        plans=[schemas.PlanOut(**p) for p in PLANS],
        free_forever=[label for _, label in FREE_FOREVER],
        free_forever_keys=[key for key, _ in FREE_FOREVER],
        current_status=getattr(account, "subscription_status", "free"),
    )


@router.post("/billing/subscribe", response_model=schemas.AccountOut, tags=["billing"])
def billing_subscribe(body: schemas.SubscribeIn,
                      account_id: uuid.UUID = Depends(current_account_id),
                      session: Session = Depends(db_session)):
    """Start a trial.

    **No payment rail is connected.** This moves the account to `trial` so the
    entitlement path is exercisable end to end; it takes no money and issues no
    receipt. Wiring bKash/Nagad and the store billing SDKs is a separate job.
    """
    if body.plan_code not in {p["code"] for p in PLANS}:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Unknown plan")
    account = session.get(Account, account_id)
    if account is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Account not found")
    trial_days = next(p["trial_days"] for p in PLANS if p["code"] == body.plan_code)
    account.subscription_status = "trial"
    account.subscription_expiry = datetime.now(timezone.utc) + timedelta(days=trial_days)
    session.flush()
    return account


# ── account preferences, export and deletion ──────────────────────────

@router.patch("/me/preferences", response_model=schemas.AccountOut, tags=["auth"])
def update_preferences(body: schemas.PreferencesIn,
                       account_id: uuid.UUID = Depends(current_account_id),
                       session: Session = Depends(db_session)):
    account = session.get(Account, account_id)
    if account is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Account not found")
    if body.locale is not None:
        account.locale = body.locale
    if body.units_prefs is not None:
        account.units_prefs = body.units_prefs
    session.flush()
    return account


@router.post("/me/export", response_model=schemas.ExportOut, tags=["auth"])
def export_account(account_id: uuid.UUID = Depends(current_account_id),
                   session: Session = Depends(db_session)):
    """Everything this account holds, in one payload.

    Free on every tier — a regulatory requirement, not a premium feature
    (PRD §11). RLS scopes every query below to what this account may see, so
    the export cannot accidentally include somebody else's record.
    """
    account = session.get(Account, account_id)
    profiles = list(session.scalars(select(Profile)))
    profile_ids = [p.id for p in profiles]

    def dump(rows, fields):
        return [{f: _jsonable(getattr(r, f, None)) for f in fields} for r in rows]

    health = list(session.scalars(
        select(HealthProfile).where(HealthProfile.profile_id.in_(profile_ids))
    )) if profile_ids else []
    risks = list(session.scalars(
        select(RiskAssessment).where(RiskAssessment.profile_id.in_(profile_ids))
    )) if profile_ids else []
    vitals = list(session.scalars(
        select(VitalLog).where(VitalLog.profile_id.in_(profile_ids))
    )) if profile_ids else []
    meals = list(session.scalars(
        select(MealLog).where(MealLog.profile_id.in_(profile_ids))
    )) if profile_ids else []
    checkins = list(session.scalars(
        select(DailyCheckin).where(DailyCheckin.profile_id.in_(profile_ids))
    )) if profile_ids else []
    activity = list(session.scalars(
        select(ActivityLog).where(ActivityLog.profile_id.in_(profile_ids))
    )) if profile_ids else []
    consents = list(session.scalars(
        select(Consent).where(Consent.account_id == account_id)
    ))

    return schemas.ExportOut(
        generated_at=datetime.now(timezone.utc),
        account={"id": str(account_id), "email": getattr(account, "email", None),
                 "home_region": getattr(account, "home_region", None),
                 "locale": getattr(account, "locale", None)},
        profiles=dump(profiles, ["id", "display_name", "profile_type", "region_pack",
                                 "created_at"]),
        consents=dump(consents, ["kind", "version", "locale", "accepted_at",
                                 "withdrawn_at"]),
        health_profiles=dump(health, ["profile_id", "sex_at_birth", "height_cm",
                                      "weight_kg", "waist_cm", "family_history",
                                      "physical_activity", "smoker",
                                      "diabetes_status", "updated_at"]),
        risk_assessments=dump(risks, ["id", "taken_at", "tier", "risk_probability",
                                      "risk_band", "confidence_low", "confidence_high",
                                      "model_version", "validation_status"]),
        vitals=dump(vitals, ["id", "recorded_at", "type", "value", "unit",
                             "context_tag"]),
        meals=dump(meals, ["id", "eaten_on", "slot", "entry_method", "note"]),
        checkins=dump(checkins, ["checkin_on", "energy", "sleep_hours", "mood",
                                 "symptoms", "note"]),
        activity=dump(activity, ["activity_on", "steps", "active_minutes", "source"]),
    )


def _jsonable(value):
    if isinstance(value, (datetime, date)):
        return value.isoformat()
    if isinstance(value, uuid.UUID):
        return str(value)
    return value


@router.delete("/me", status_code=status.HTTP_204_NO_CONTENT, tags=["auth"])
def delete_account(confirm_email: str,
                   account_id: uuid.UUID = Depends(current_account_id),
                   session: Session = Depends(db_session)):
    """Soft-delete. Requires the account's own email as confirmation.

    Soft rather than hard because a health record deleted by a mistyped tap is
    not recoverable, and because retention obligations outlive the account.
    A purge job is a separate, deliberate operation.
    """
    account = session.get(Account, account_id)
    if account is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Account not found")
    if confirm_email.strip().lower() != account.email.lower():
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            "Type your account email exactly to confirm deletion.")
    account.deleted_at = datetime.now(timezone.utc)
    session.flush()
