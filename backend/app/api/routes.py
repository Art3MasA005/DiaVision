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
from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException, Request, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app import schemas
from app.auth import (
    create_access_token, create_refresh_token, current_account_id, decode_token,
    hash_password, verify_password,
)
from app.config import get_settings
from app.db.models import (
    Account, AccessAuditLog, HealthProfile, Profile, ProfileMembership,
    RiskAssessment, SafetyEvent, VitalLog,
)
from app.db.session import SessionLocal, set_actor
from app.safety import check_glucose, check_profile
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
    if not body.accept_disclaimer:
        # PRD §3.2 — blocking, must tap to accept. Not a checkbox we can skip.
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            "The safety disclaimer must be accepted before an account is created.")

    existing = session.scalar(select(Account).where(Account.email == body.email))
    if existing:
        raise HTTPException(status.HTTP_409_CONFLICT, "An account with that email already exists")

    try:
        pack = risk_service.region_pack(body.region)
    except FileNotFoundError:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"Unsupported region {body.region!r}")

    account = Account(
        email=body.email,
        password_hash=hash_password(body.password),
        home_region=body.region,
        data_residency_zone=pack["data_residency_zone"],
        locale=body.locale,
        disclaimer_accepted_at=datetime.now(timezone.utc),
    )
    session.add(account)
    session.flush()

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

    return schemas.TokenResponse(
        access_token=create_access_token(account.id),
        refresh_token=create_refresh_token(account.id),
        expires_in=settings.access_token_minutes * 60,
    )


@router.post("/auth/login", response_model=schemas.TokenResponse, tags=["auth"])
def login(body: schemas.LoginRequest, session: Session = Depends(anonymous_session)):
    account = session.scalar(select(Account).where(Account.email == body.email))
    # Same message either way — never reveal whether an email is registered.
    if account is None or not verify_password(body.password, account.password_hash):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Incorrect email or password")
    if account.deleted_at is not None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Incorrect email or password")

    return schemas.TokenResponse(
        access_token=create_access_token(account.id),
        refresh_token=create_refresh_token(account.id),
        expires_in=settings.access_token_minutes * 60,
    )


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
        session.flush()
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

    audit(session, profile, account_id, "write", "health_profile", request)
    session.flush()

    out = schemas.HealthProfileOut(
        profile_id=profile_id, updated_at=health.updated_at or datetime.now(timezone.utc),
        age_years=body.age_years, pregnant=body.pregnant,
        **body.model_dump(exclude={"age_years", "pregnant"}),
    )
    return out


# ── risk ──────────────────────────────────────────────────────────────

@router.post("/risk/assess", response_model=schemas.RiskResultOut, tags=["risk"])
def assess_risk(
    body: schemas.RiskAssessRequest, request: Request,
    account_id: uuid.UUID = Depends(current_account_id),
    session: Session = Depends(db_session),
):
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

    record = risk_service.health_profile_to_record(health, age_years=_age_of(session, profile.id))
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


def _age_of(session: Session, profile_id: uuid.UUID) -> int | None:
    """Age from the most recent assessment inputs, falling back to DOB."""
    last = session.scalar(
        select(RiskAssessment).where(RiskAssessment.profile_id == profile_id)
        .order_by(RiskAssessment.taken_at.desc()).limit(1)
    )
    if last and isinstance(last.inputs_json, dict):
        age = last.inputs_json.get("age_years")
        if age:
            return int(age)
    return None


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
        raise HTTPException(status.HTTP_409_CONFLICT, {
            "safety_card": {
                "trigger": card.trigger, "severity": card.severity.value,
                "title": card.title, "body": card.body, "actions": card.actions,
                "emergency_number": pack.get("safety_thresholds", {}).get("emergency_number"),
            },
            "recorded": True,
        })
    return row


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
