"""Password reset, session cut-off, and the declared cutoff group.

Revision ID: 0005
Revises: 0004
Create Date: 2026-11-24

  * `password_resets`  emailed 6-digit codes (only an HMAC is stored), behind
    account-scoped RLS
  * `accounts.tokens_valid_after`  tokens issued before it are refused, which
    is how a reset signs out every other session
  * `health_profiles.ancestry_cutoff_group`  the optional, user-declared
    population whose published cutoffs to use. Closes the diaspora gap: the
    ML layer already applied it, but the API never stored it, so a
    Bangladeshi in London was still scored on European cutoffs

Each step checks what exists first. Revision 0001 builds from the live model
metadata, so on a fresh database these objects are already there by the time
this runs.
"""
from __future__ import annotations

from pathlib import Path
from typing import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0005"
down_revision: str | None = "0004"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

RLS_SQL = Path(__file__).resolve().parents[2] / "app" / "db" / "rls.sql"
_UUID = postgresql.UUID(as_uuid=True)

ANCESTRY_CHECK = (
    "ancestry_cutoff_group IS NULL OR ancestry_cutoff_group IN "
    "('south_asian','east_asian','european','african','middle_eastern','hispanic')"
)


def _columns(table: str) -> set[str]:
    return {c["name"] for c in sa.inspect(op.get_bind()).get_columns(table)}


def _checks(table: str) -> set[str]:
    return {c["name"] for c in sa.inspect(op.get_bind()).get_check_constraints(table)}


def upgrade() -> None:
    insp = sa.inspect(op.get_bind())

    if not insp.has_table("password_resets"):
        op.create_table(
            "password_resets",
            sa.Column("id", _UUID, primary_key=True),
            sa.Column("account_id", _UUID,
                      sa.ForeignKey("accounts.id", ondelete="CASCADE"), nullable=False),
            sa.Column("code_hash", sa.String(64), nullable=False),
            sa.Column("created_at", sa.DateTime(timezone=True),
                      server_default=sa.func.now(), nullable=False),
            sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("attempts", sa.Integer, nullable=False, server_default="0"),
            sa.Column("locked_until", sa.DateTime(timezone=True)),
            sa.Column("verified_at", sa.DateTime(timezone=True)),
            sa.Column("used_at", sa.DateTime(timezone=True)),
            sa.CheckConstraint("attempts BETWEEN 0 AND 100", name="ck_reset_attempts"),
        )
        op.create_index("ix_password_resets_account_created", "password_resets",
                        ["account_id", "created_at"])

    if "tokens_valid_after" not in _columns("accounts"):
        op.add_column("accounts",
                      sa.Column("tokens_valid_after", sa.DateTime(timezone=True)))

    if "ancestry_cutoff_group" not in _columns("health_profiles"):
        op.add_column("health_profiles",
                      sa.Column("ancestry_cutoff_group", sa.String(24)))
    if "ck_ancestry_cutoff_group" not in _checks("health_profiles"):
        op.create_check_constraint("ck_ancestry_cutoff_group", "health_profiles",
                                   ANCESTRY_CHECK)

    # Applies the password_resets policy. Idempotent.
    op.execute(sa.text(RLS_SQL.read_text(encoding="utf-8")))


def downgrade() -> None:
    op.drop_constraint("ck_ancestry_cutoff_group", "health_profiles", type_="check")
    op.drop_column("health_profiles", "ancestry_cutoff_group")
    op.drop_column("accounts", "tokens_valid_after")
    op.drop_index("ix_password_resets_account_created", table_name="password_resets")
    op.drop_table("password_resets")
