"""Authentication: password hashing and JWT issue/verify.

Deliberately minimal. The interesting authorisation work does not happen here —
it happens in the database, via the row-level security policies in rls.sql. A
token proves *who you are*; it grants access to nothing on its own.
"""

from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

import bcrypt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jose import JWTError, jwt

from app.config import get_settings

settings = get_settings()
bearer = HTTPBearer(auto_error=False)


def hash_password(password: str) -> str:
    # bcrypt truncates silently past 72 bytes, so reject rather than accept a
    # password where the tail does nothing.
    if len(password.encode("utf-8")) > 72:
        raise ValueError("Password must be at most 72 bytes")
    return bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def verify_password(password: str, hashed: str) -> bool:
    try:
        return bcrypt.checkpw(password.encode("utf-8"), hashed.encode("utf-8"))
    except (ValueError, TypeError):
        return False


def _token(subject: str, expires: timedelta, token_type: str) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": subject,
        "type": token_type,
        "iat": now,
        # `iat` is whole seconds. This is the exact issue time, so a session
        # started a moment before a password reset is still recognised as
        # older than it. See `issued_before`.
        "iat_us": int(now.timestamp() * 1_000_000),
        "exp": now + expires,
        "jti": str(uuid.uuid4()),
    }
    return jwt.encode(payload, settings.jwt_secret, algorithm=settings.jwt_algorithm)


def create_access_token(account_id: uuid.UUID | str) -> str:
    return _token(str(account_id), timedelta(minutes=settings.access_token_minutes), "access")


def create_refresh_token(account_id: uuid.UUID | str) -> str:
    return _token(str(account_id), timedelta(days=settings.refresh_token_days), "refresh")


def decode_token(token: str, expect: str = "access") -> dict[str, Any]:
    try:
        payload = jwt.decode(token, settings.jwt_secret, algorithms=[settings.jwt_algorithm])
    except JWTError as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, f"Invalid token: {exc}") from exc
    if payload.get("type") != expect:
        # A refresh token must not be usable as an access token.
        raise HTTPException(status.HTTP_401_UNAUTHORIZED,
                            f"Expected a {expect} token, got {payload.get('type')!r}")
    return payload


async def current_token(
    creds: HTTPAuthorizationCredentials | None = Depends(bearer),
) -> dict[str, Any]:
    """The verified access-token claims. Cached per request by FastAPI."""
    if creds is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Not authenticated",
                            headers={"WWW-Authenticate": "Bearer"})
    return decode_token(creds.credentials, expect="access")


def issued_before(payload: dict[str, Any], cutoff: datetime | None) -> bool:
    """Whether a token predates `accounts.tokens_valid_after`.

    Compared to the microsecond via `iat_us`. A token without it predates
    this check and falls back to whole-second `iat`.
    """
    if cutoff is None:
        return False
    iat_us = payload.get("iat_us")
    if isinstance(iat_us, int):
        return iat_us < int(cutoff.timestamp() * 1_000_000)
    iat = payload.get("iat")
    if not isinstance(iat, (int, float)):
        return True
    return int(iat) < int(cutoff.timestamp())


async def current_account_id(payload: dict[str, Any] = Depends(current_token)) -> uuid.UUID:
    try:
        return uuid.UUID(payload["sub"])
    except (KeyError, ValueError) as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Malformed token subject") from exc
