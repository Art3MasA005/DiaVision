"""Split consent into its own table; drop accounts.disclaimer_accepted_at.

Revision ID: 0002
Revises: 0001
Create Date: 2026-08-14

A single timestamp column could not answer "which version did they agree to,
and when?", and it conflated two agreements a user makes at different moments:
the Terms at signup, and the medical disclaimer on its own blocking screen
afterwards. The design handoff separates them and is right to.

Rows are append-only — a re-accept or a withdrawal writes a new row rather
than editing an old one, so the agreement history survives.
"""
from __future__ import annotations

from pathlib import Path
from typing import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "0002"
down_revision: str | None = "0001"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

RLS_SQL = Path(__file__).resolve().parents[2] / "app" / "db" / "rls.sql"


def upgrade() -> None:
    op.create_table(
        "consents",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("account_id", postgresql.UUID(as_uuid=True),
                  sa.ForeignKey("accounts.id", ondelete="CASCADE"), nullable=False),
        sa.Column("kind", sa.String(32), nullable=False),
        sa.Column("version", sa.String(16), nullable=False),
        sa.Column("locale", sa.String(8), nullable=False, server_default="en"),
        sa.Column("accepted_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.Column("withdrawn_at", sa.DateTime(timezone=True)),
        sa.Column("ip_hash", sa.String(64)),
        sa.CheckConstraint("kind IN ('terms','privacy','medical_disclaimer','model_improvement')",
                           name="ck_consent_kind"),
    )
    op.create_index("ix_consents_account_id", "consents", ["account_id"])
    op.create_index("ix_consent_account_kind", "consents",
                    ["account_id", "kind", "accepted_at"])

    # Carry existing acceptances across as BOTH kinds. Those users genuinely
    # saw a combined screen, so recording only one would understate what they
    # agreed to, and recording neither would lock them out of their own data.
    op.execute(sa.text("""
        INSERT INTO consents (id, account_id, kind, version, locale, accepted_at)
        SELECT gen_random_uuid(), id, k.kind, '1.0', locale, disclaimer_accepted_at
        FROM accounts, (VALUES ('terms'), ('medical_disclaimer')) AS k(kind)
        WHERE disclaimer_accepted_at IS NOT NULL
    """))

    op.drop_column("accounts", "disclaimer_accepted_at")

    # Re-run the whole policy file: it is idempotent (every CREATE POLICY is
    # preceded by DROP POLICY IF EXISTS) and this is what applies the new
    # consents policies without duplicating them here.
    op.execute(sa.text(RLS_SQL.read_text(encoding="utf-8")))


def downgrade() -> None:
    op.add_column("accounts",
                  sa.Column("disclaimer_accepted_at", sa.DateTime(timezone=True)))
    op.execute(sa.text("""
        UPDATE accounts a SET disclaimer_accepted_at = c.accepted_at
        FROM consents c
        WHERE c.account_id = a.id AND c.kind = 'medical_disclaimer'
          AND c.withdrawn_at IS NULL
    """))
    op.drop_index("ix_consent_account_kind", table_name="consents")
    op.drop_index("ix_consents_account_id", table_name="consents")
    op.drop_table("consents")
