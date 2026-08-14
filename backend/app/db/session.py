"""Database engine and the request-scoped session that carries the actor.

Every request runs inside a transaction that begins by declaring who is
acting:

    SET LOCAL app.account_id = '<uuid>';

`SET LOCAL` is scoped to the transaction, so a pooled connection cannot leak
one user's identity into the next request. Every RLS policy in rls.sql reads
that setting; with it unset, the policies match nothing and the caller sees an
empty database rather than someone else's.
"""

from __future__ import annotations

import uuid
from contextlib import contextmanager
from typing import Iterator

from sqlalchemy import create_engine, event, text
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker

from app.config import get_settings

_settings = get_settings()

engine: Engine = create_engine(
    _settings.database_url,
    pool_pre_ping=True,
    pool_size=10,
    max_overflow=20,
    echo=False,
)

SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


@event.listens_for(engine, "connect")
def _assert_not_superuser(dbapi_conn, _record):
    """Refuse to run as a superuser — it silently bypasses every RLS policy.

    This is a loud failure by design. A superuser connection would make every
    isolation test pass while providing no isolation at all in production,
    which is the worst possible combination.
    """
    with dbapi_conn.cursor() as cur:
        cur.execute("SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user")
        row = cur.fetchone()
    if row and (row[0] or row[1]):
        raise RuntimeError(
            f"Refusing to connect as {_settings.postgres_user!r}: it has SUPERUSER "
            f"or BYPASSRLS, which disables row-level security. Use the byebye_app "
            f"role created by backend/scripts/setup_db.py."
        )


def set_actor(session: Session, account_id: uuid.UUID | str | None) -> None:
    """Declare the acting account for this transaction.

    Passing None leaves the setting empty, which denies access to everything —
    the correct default for an unauthenticated request.
    """
    session.execute(
        text("SELECT set_config('app.account_id', :v, true)"),
        {"v": str(account_id) if account_id else ""},
    )


@contextmanager
def session_for(account_id: uuid.UUID | str | None) -> Iterator[Session]:
    """A transaction scoped to one actor. Commits on success, rolls back on error."""
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
