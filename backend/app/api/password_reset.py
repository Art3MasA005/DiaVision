"""Password reset: email -> 6-digit code -> new password.

    POST /auth/password/reset-request   {email}                -> 202
    POST /auth/password/reset-verify    {email, code}          -> {reset_token}
    POST /auth/password/reset           {reset_token, new_password} -> 204

Rules (handoff, screen "forgot"):

  * The same answer whether or not the email has an account. reset-request
    always says 202, and the email goes out in a background task after the
    response, so the slow part (talking to the mail server) never shows up
    in how long the request took.
  * The code expires after 10 minutes. 5 wrong tries lock reset for 30.
  * A new code goes out at most once every 60 seconds. A request inside that
    window still answers 202 but sends nothing.
  * A successful reset stamps `accounts.tokens_valid_after`, which signs out
    every session issued before it, on every device.

There is no actor at the start of these requests, only an email. The account
is found with `app_lookup_account_for_auth` (the narrow SECURITY DEFINER
lookup login uses) and then declared as the actor, as signup does, so every
later query still runs under row-level security.

Errors carry a machine-readable `reason` the app turns into its own words:
`reset_unavailable` (503), `invalid_code` (400), `too_many_attempts` (429)
and `invalid_reset_token` (400).
"""

from __future__ import annotations

import hashlib
import hmac
import secrets
import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Response, status
from jose import JWTError, jwt
from sqlalchemy import select, text, update
from sqlalchemy.orm import Session

from app import schemas
from app.api.routes import anonymous_session
from app.auth import hash_password
from app.config import get_settings
from app.db.models import Account, PasswordReset
from app.db.session import set_actor
from app.services import mailer

router = APIRouter(prefix="/auth/password", tags=["auth"])

CODE_TTL = timedelta(minutes=10)
RESEND_AFTER = timedelta(seconds=60)
MAX_ATTEMPTS = 5
LOCK_FOR = timedelta(minutes=30)
RESET_TOKEN_TTL = timedelta(minutes=15)
_TOKEN_TYPE = "password_reset"


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _hash(row_id: uuid.UUID, code: str) -> str:
    key = get_settings().jwt_secret.encode("utf-8")
    return hmac.new(key, f"{row_id}:{code}".encode("utf-8"), hashlib.sha256).hexdigest()


def _lookup(session: Session, email: str) -> uuid.UUID | None:
    row = session.execute(
        text("SELECT account_id, deleted_at FROM app_lookup_account_for_auth(:email)"),
        {"email": email},
    ).one_or_none()
    if row is None or row.deleted_at is not None:
        return None
    return row.account_id


def _latest(session: Session, account_id: uuid.UUID) -> PasswordReset | None:
    return session.scalar(
        select(PasswordReset).where(PasswordReset.account_id == account_id)
        .order_by(PasswordReset.created_at.desc()).limit(1)
    )


def _fail(code: int, reason: str, message: str, **extra) -> HTTPException:
    return HTTPException(code, {"reason": reason, "message": message, **extra})


_INVALID = ("invalid_code", "That code is wrong or has expired.")


def _message(locale: str, code: str) -> tuple[str, str]:
    if locale.startswith("bn"):
        return (
            "DiaVision পাসওয়ার্ড রিসেট কোড",
            f"আপনার কোড: {code}\n\n"
            "কোডটি ১০ মিনিট কাজ করবে। আপনি রিসেট না চাইলে এই ইমেইলটি উপেক্ষা "
            "করুন, আপনার পাসওয়ার্ড বদলাবে না।\n\nকাউকে এই কোড বলবেন না।",
        )
    return (
        "Your DiaVision password reset code",
        f"Your code: {code}\n\n"
        "It works for 10 minutes. If you did not ask to reset your password, "
        "ignore this email and nothing will change.\n\nNever share this code.",
    )


# ── 1 · request a code ───────────────────────────────────────────────

@router.post("/reset-request", status_code=status.HTTP_202_ACCEPTED,
             response_model=schemas.ResetRequestOut)
def request_code(body: schemas.ResetRequestIn, background: BackgroundTasks,
                 session: Session = Depends(anonymous_session)):
    # Refused for every address alike, so it says nothing about any of them.
    if not mailer.available():
        raise _fail(503, "reset_unavailable", "Password reset is not available right now.")

    out = schemas.ResetRequestOut(resend_after_seconds=int(RESEND_AFTER.total_seconds()))
    email = body.email
    account_id = _lookup(session, email)
    if account_id is None:
        return out

    set_actor(session, account_id)
    now = _now()
    last = _latest(session, account_id)
    if last is not None:
        if last.locked_until is not None and last.locked_until > now:
            return out
        if last.created_at > now - RESEND_AFTER:
            return out

    # One live code at a time: a new one retires every earlier one.
    session.execute(
        update(PasswordReset)
        .where(PasswordReset.account_id == account_id, PasswordReset.used_at.is_(None))
        .values(used_at=now)
    )
    code = f"{secrets.randbelow(1_000_000):06d}"
    row = PasswordReset(id=uuid.uuid4(), account_id=account_id, code_hash="",
                        expires_at=now + CODE_TTL, created_at=now)
    row.code_hash = _hash(row.id, code)
    session.add(row)
    locale = session.scalar(select(Account.locale).where(Account.id == account_id)) or "en"
    session.commit()

    subject, text_body = _message(locale, code)
    background.add_task(mailer.send, email, subject, text_body)
    return out


# ── 2 · check the code ───────────────────────────────────────────────

_DIGITS = str.maketrans("০১২৩৪৫৬৭৮৯", "0123456789")


@router.post("/reset-verify", response_model=schemas.ResetVerifyOut)
def verify_code(body: schemas.ResetVerifyIn, session: Session = Depends(anonymous_session)):
    code = body.code.translate(_DIGITS).strip()
    account_id = _lookup(session, body.email)
    if account_id is None:
        # Same work as a real check, so timing does not separate the cases.
        _hash(uuid.uuid4(), code)
        raise _fail(400, *_INVALID)

    set_actor(session, account_id)
    now = _now()
    row = _latest(session, account_id)
    if row is not None and row.locked_until is not None and row.locked_until > now:
        raise _fail(429, "too_many_attempts", "Too many wrong codes. Try again later.",
                    retry_after_seconds=int((row.locked_until - now).total_seconds()))
    if row is None or row.used_at is not None or row.expires_at <= now:
        raise _fail(400, *_INVALID)

    if not hmac.compare_digest(row.code_hash, _hash(row.id, code)):
        row.attempts += 1
        locked = row.attempts >= MAX_ATTEMPTS
        if locked:
            row.locked_until = now + LOCK_FOR
        # Commit before raising: `anonymous_session` rolls back on any
        # exception, which would otherwise forget the attempt and make the
        # limit unenforceable.
        session.commit()
        if locked:
            raise _fail(429, "too_many_attempts", "Too many wrong codes. Try again later.",
                        retry_after_seconds=int(LOCK_FOR.total_seconds()))
        raise _fail(400, *_INVALID, attempts_left=MAX_ATTEMPTS - row.attempts)

    row.verified_at = now
    token = jwt.encode(
        {"sub": str(account_id), "rid": str(row.id), "type": _TOKEN_TYPE,
         "iat": now, "exp": now + RESET_TOKEN_TTL},
        get_settings().jwt_secret, algorithm=get_settings().jwt_algorithm,
    )
    session.commit()
    return schemas.ResetVerifyOut(reset_token=token)


# ── 3 · set the new password ─────────────────────────────────────────

_BAD_TOKEN = ("invalid_reset_token", "This reset has expired. Start again.")


@router.post("/reset", status_code=status.HTTP_204_NO_CONTENT)
def set_password(body: schemas.ResetSetIn, session: Session = Depends(anonymous_session)):
    s = get_settings()
    try:
        claims = jwt.decode(body.reset_token, s.jwt_secret, algorithms=[s.jwt_algorithm])
        if claims.get("type") != _TOKEN_TYPE:
            raise JWTError("wrong type")
        account_id = uuid.UUID(claims["sub"])
        row_id = uuid.UUID(claims["rid"])
    except (JWTError, KeyError, ValueError):
        raise _fail(400, *_BAD_TOKEN)

    set_actor(session, account_id)
    row = session.get(PasswordReset, row_id)
    account = session.get(Account, account_id)
    if (row is None or account is None or account.deleted_at is not None
            or row.account_id != account_id or row.verified_at is None
            or row.used_at is not None):
        raise _fail(400, *_BAD_TOKEN)

    try:
        account.password_hash = hash_password(body.new_password)
    except ValueError:
        raise HTTPException(422, "Password must be at most 72 bytes")

    now = _now()
    row.used_at = now
    # Signs out every session, on every device, that existed before now.
    account.tokens_valid_after = now
    session.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
