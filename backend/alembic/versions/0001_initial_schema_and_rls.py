"""Initial schema, plus row-level security.

Revision ID: 0001
Revises:
Create Date: 2026-08-14

Creates the Account/Profile split (PRD §8) and applies the RLS policies from
app/db/rls.sql. Those two halves belong in the same migration: a schema
carrying health data without its isolation policies is not a valid state for
this database to be in, even briefly.
"""
from __future__ import annotations

from pathlib import Path
from typing import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "0001"
down_revision: str | None = None
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

RLS_SQL = Path(__file__).resolve().parents[2] / "app" / "db" / "rls.sql"


def upgrade() -> None:
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from app.db.models import Base

    bind = op.get_bind()

    # The initial migration builds from the model metadata. Every migration
    # after this one is a hand-reviewed delta — this shortcut is only sound
    # because there is no prior state to migrate from.
    Base.metadata.create_all(bind=bind)

    op.execute(sa.text(RLS_SQL.read_text(encoding="utf-8")))


def downgrade() -> None:
    import sys

    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    from app.db.models import Base

    bind = op.get_bind()
    op.execute(sa.text("DROP FUNCTION IF EXISTS app_can_write_profile(uuid)"))
    op.execute(sa.text("DROP FUNCTION IF EXISTS app_can_read_profile(uuid)"))
    op.execute(sa.text("DROP FUNCTION IF EXISTS app_current_account()"))
    Base.metadata.drop_all(bind=bind)
