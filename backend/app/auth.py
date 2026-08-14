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


async def current_account_id(
    creds: HTTPAuthorizationCredentials | None = Depends(bearer),
) -> uuid.UUID:
    if creds is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Not authenticated",
                            headers={"WWW-Authenticate": "Bearer"})
    payload = decode_token(creds.credentials, expect="access")
    try:
        return uuid.UUID(payload["sub"])
    except (KeyError, ValueError) as exc:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Malformed token subject") from exc
