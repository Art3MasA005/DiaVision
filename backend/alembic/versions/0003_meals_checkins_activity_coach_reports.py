"""Meals, check-ins, activity, coach and reports.

Revision ID: 0003
Revises: 0002
Create Date: 2026-08-15

Everything the app's remaining screens need, added in one migration because
they share the same shape: profile-scoped health data behind row-level
security, keyed on `profile_id` and never on `account_id` (PRD §8).

`food_items` is the one exception — reference data with no profile column. It
is deliberately NOT RLS-protected and NOT seeded from the Bangladesh food
composition table, which `packs/bd.json` records as `permission_pending`. The
seeded rows are widely-published approximations marked `source='placeholder'`,
and the API returns that field so the client can say so.

`meal_log_items` carries a denormalised `profile_id` for the same reason
`profile_memberships` carries `owner_account_id`: an RLS policy that had to
join `meal_logs` would inherit that table's policy, and the dependency graph
in rls.sql has to stay a DAG.
"""
from __future__ import annotations

from pathlib import Path
from typing import Sequence

import sqlalchemy as sa
from alembic import op

import sys as _sys
_sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from app.db.migration_guards import Guarded  # noqa: E402
from sqlalchemy.dialects import postgresql

revision: str = "0003"
down_revision: str | None = "0002"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

RLS_SQL = Path(__file__).resolve().parents[2] / "app" / "db" / "rls.sql"

_UUID = postgresql.UUID(as_uuid=True)


def _profile_fk(nullable: bool = False) -> sa.Column:
    return sa.Column("profile_id", _UUID,
                     sa.ForeignKey("profiles.id", ondelete="CASCADE"),
                     nullable=nullable)


def upgrade() -> None:
    # Guarded: on a fresh database 0001 already built these from the models.
    # See app/db/migration_guards.py.
    g = Guarded(op)
    # ── reference data ────────────────────────────────────────────────
    g.create_table(
        "food_items",
        sa.Column("id", _UUID, primary_key=True),
        sa.Column("region", sa.String(2), nullable=False, server_default="bd"),
        sa.Column("name_en", sa.String(160), nullable=False),
        sa.Column("name_local", sa.String(160)),
        sa.Column("kcal_per_100g", sa.Float, nullable=False),
        sa.Column("carbs_g_per_100g", sa.Float, nullable=False, server_default="0"),
        sa.Column("protein_g_per_100g", sa.Float, nullable=False, server_default="0"),
        sa.Column("fat_g_per_100g", sa.Float, nullable=False, server_default="0"),
        sa.Column("fibre_g_per_100g", sa.Float, nullable=False, server_default="0"),
        sa.Column("glycemic_index", sa.Float),
        sa.Column("portion_grams", postgresql.JSONB, nullable=False,
                  server_default=sa.text("'{}'::jsonb")),
        sa.Column("source", sa.String(32), nullable=False, server_default="placeholder"),
        sa.Column("created_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("kcal_per_100g BETWEEN 0 AND 900", name="ck_food_kcal"),
        sa.CheckConstraint("glycemic_index IS NULL OR glycemic_index BETWEEN 0 AND 110",
                           name="ck_food_gi"),
        sa.CheckConstraint("source IN ('placeholder','licensed','user')",
                           name="ck_food_source"),
    )
    g.create_index("ix_food_items_region", "food_items", ["region"])
    g.create_index("ix_food_region_name", "food_items", ["region", "name_en"])

    # ── meals ─────────────────────────────────────────────────────────
    g.create_table(
        "meal_logs",
        sa.Column("id", _UUID, primary_key=True),
        _profile_fk(),
        sa.Column("eaten_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.Column("eaten_on", sa.Date, nullable=False),
        sa.Column("slot", sa.String(16), nullable=False),
        sa.Column("note", sa.Text),
        sa.Column("entry_method", sa.String(16), nullable=False, server_default="manual"),
        sa.Column("created_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("entry_method IN ('manual','photo')",
                           name="ck_meal_entry_method"),
    )
    g.create_index("ix_meal_logs_profile_id", "meal_logs", ["profile_id"])
    g.create_index("ix_meal_logs_eaten_on", "meal_logs", ["eaten_on"])
    g.create_index("ix_meal_profile_day", "meal_logs", ["profile_id", "eaten_on"])

    g.create_table(
        "meal_log_items",
        sa.Column("id", _UUID, primary_key=True),
        sa.Column("meal_id", _UUID,
                  sa.ForeignKey("meal_logs.id", ondelete="CASCADE"), nullable=False),
        _profile_fk(),
        sa.Column("food_id", _UUID,
                  sa.ForeignKey("food_items.id", ondelete="SET NULL")),
        sa.Column("name_snapshot", sa.String(160), nullable=False),
        sa.Column("quantity", sa.Float, nullable=False, server_default="1"),
        sa.Column("unit", sa.String(24), nullable=False, server_default="serving"),
        sa.Column("grams", sa.Float, nullable=False),
        sa.Column("kcal", sa.Float, nullable=False),
        sa.Column("carbs_g", sa.Float, nullable=False, server_default="0"),
        sa.Column("protein_g", sa.Float, nullable=False, server_default="0"),
        sa.Column("fat_g", sa.Float, nullable=False, server_default="0"),
        sa.Column("fibre_g", sa.Float, nullable=False, server_default="0"),
        sa.Column("glycemic_load", sa.Float),
        sa.Column("recognition_confidence", sa.Float),
        sa.CheckConstraint("grams > 0 AND grams <= 5000", name="ck_item_grams"),
        sa.CheckConstraint(
            "recognition_confidence IS NULL OR recognition_confidence BETWEEN 0 AND 1",
            name="ck_item_confidence"),
    )
    g.create_index("ix_meal_log_items_meal_id", "meal_log_items", ["meal_id"])
    g.create_index("ix_meal_log_items_profile_id", "meal_log_items", ["profile_id"])

    # ── check-ins ─────────────────────────────────────────────────────
    g.create_table(
        "daily_checkins",
        sa.Column("id", _UUID, primary_key=True),
        _profile_fk(),
        sa.Column("checkin_on", sa.Date, nullable=False),
        sa.Column("energy", sa.Integer),
        sa.Column("sleep_hours", sa.Float),
        sa.Column("mood", sa.Integer),
        sa.Column("symptoms", postgresql.ARRAY(sa.Text), nullable=False,
                  server_default=sa.text("'{}'::text[]")),
        sa.Column("note", sa.Text),
        sa.Column("created_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("energy IS NULL OR energy BETWEEN 1 AND 5",
                           name="ck_checkin_energy"),
        sa.CheckConstraint("mood IS NULL OR mood BETWEEN 1 AND 5",
                           name="ck_checkin_mood"),
        sa.CheckConstraint("sleep_hours IS NULL OR sleep_hours BETWEEN 0 AND 24",
                           name="ck_checkin_sleep"),
        sa.UniqueConstraint("profile_id", "checkin_on", name="uq_checkin_profile_day"),
    )
    g.create_index("ix_daily_checkins_profile_id", "daily_checkins", ["profile_id"])

    # ── activity ──────────────────────────────────────────────────────
    g.create_table(
        "activity_logs",
        sa.Column("id", _UUID, primary_key=True),
        _profile_fk(),
        sa.Column("activity_on", sa.Date, nullable=False),
        sa.Column("steps", sa.Integer, nullable=False, server_default="0"),
        sa.Column("active_minutes", sa.Integer, nullable=False, server_default="0"),
        sa.Column("distance_km", sa.Float),
        sa.Column("source", sa.String(24), nullable=False, server_default="manual"),
        sa.Column("updated_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("steps BETWEEN 0 AND 200000", name="ck_activity_steps"),
        sa.CheckConstraint("active_minutes BETWEEN 0 AND 1440",
                           name="ck_activity_minutes"),
        sa.UniqueConstraint("profile_id", "activity_on", name="uq_activity_profile_day"),
    )
    g.create_index("ix_activity_logs_profile_id", "activity_logs", ["profile_id"])

    # ── coach ─────────────────────────────────────────────────────────
    g.create_table(
        "coach_messages",
        sa.Column("id", _UUID, primary_key=True),
        _profile_fk(),
        sa.Column("created_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.Column("role", sa.String(12), nullable=False),
        sa.Column("body", sa.Text, nullable=False),
        sa.Column("intercepted", sa.Boolean, nullable=False,
                  server_default=sa.text("false")),
        sa.CheckConstraint("role IN ('user','coach')", name="ck_coach_role"),
    )
    g.create_index("ix_coach_messages_profile_id", "coach_messages", ["profile_id"])
    g.create_index("ix_coach_profile_time", "coach_messages",
                    ["profile_id", "created_at"])

    # ── reports ───────────────────────────────────────────────────────
    g.create_table(
        "reports",
        sa.Column("id", _UUID, primary_key=True),
        _profile_fk(),
        sa.Column("generated_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.Column("period_start", sa.Date, nullable=False),
        sa.Column("period_end", sa.Date, nullable=False),
        sa.Column("payload_json", postgresql.JSONB, nullable=False),
        sa.Column("share_expires_at", sa.DateTime(timezone=True)),
        sa.CheckConstraint("period_end >= period_start", name="ck_report_period"),
    )
    g.create_index("ix_reports_profile_id", "reports", ["profile_id"])
    g.create_index("ix_report_profile_time", "reports", ["profile_id", "generated_at"])

    # Re-run the whole policy file. It is idempotent — every CREATE POLICY is
    # preceded by DROP POLICY IF EXISTS — and this is what applies RLS to the
    # six new profile-scoped tables without duplicating the rules here.
    op.execute(sa.text(RLS_SQL.read_text(encoding="utf-8")))

    _seed_foods()


def _seed_foods() -> None:
    """A small starter set so the tracker is usable on day one.

    THESE ARE NOT LICENSED COMPOSITION VALUES. They are widely-published
    approximations for common items, rounded, and every row is marked
    `source='placeholder'` so the API and the UI can say so. The Bangladesh
    food composition table (INFS, 2013) is `permission_pending` in
    `packs/bd.json` and nothing from it is reproduced here.

    Glycemic index is left NULL where no widely-agreed value exists, so the
    glycemic load is omitted rather than fabricated.
    """
    rows = [
        # name_en, name_local, kcal, carbs, protein, fat, fibre, GI, portions
        ("Boiled rice", "ভাত", 130, 28.0, 2.7, 0.3, 0.4, 73,
         {"cup": 158, "bowl": 200, "ladle": 90, "serving": 158}),
        ("Roti (wheat)", "রুটি", 297, 51.0, 11.0, 4.0, 8.0, 62,
         {"piece": 40, "serving": 40}),
        ("Paratha", "পরোটা", 330, 45.0, 7.0, 13.0, 3.0, None,
         {"piece": 60, "serving": 60}),
        ("Lentil dal", "ডাল", 116, 20.0, 9.0, 0.4, 8.0, 29,
         {"bowl": 180, "ladle": 80, "cup": 150, "serving": 180}),
        ("Fish curry", "মাছের ঝোল", 145, 4.0, 17.0, 7.0, 0.6, None,
         {"bowl": 180, "piece": 80, "serving": 150}),
        ("Chicken curry", "মুরগির ঝোল", 180, 5.0, 18.0, 10.0, 0.8, None,
         {"bowl": 180, "piece": 90, "serving": 150}),
        ("Egg, boiled", "সিদ্ধ ডিম", 155, 1.1, 13.0, 11.0, 0.0, None,
         {"piece": 50, "serving": 50}),
        ("Mixed vegetables", "সবজি", 65, 10.0, 2.5, 1.5, 3.5, 35,
         {"bowl": 150, "cup": 130, "serving": 150}),
        ("Potato, boiled", "আলু", 87, 20.0, 2.0, 0.1, 1.8, 78,
         {"piece": 90, "cup": 150, "serving": 120}),
        ("Puffed rice", "মুড়ি", 402, 89.0, 7.5, 1.0, 1.5, 87,
         {"cup": 25, "bowl": 40, "serving": 30}),
        ("Banana", "কলা", 89, 23.0, 1.1, 0.3, 2.6, 51,
         {"piece": 118, "serving": 118}),
        ("Mango", "আম", 60, 15.0, 0.8, 0.4, 1.6, 51,
         {"piece": 200, "cup": 165, "serving": 165}),
        ("Milk tea with sugar", "দুধ চা", 62, 9.0, 1.8, 1.9, 0.0, None,
         {"cup": 150, "serving": 150}),
        ("Tea without sugar", "চিনি ছাড়া চা", 2, 0.4, 0.1, 0.0, 0.0, None,
         {"cup": 150, "serving": 150}),
        ("Yoghurt, plain", "টক দই", 61, 4.7, 3.5, 3.3, 0.0, 35,
         {"bowl": 150, "cup": 130, "serving": 150}),
        ("Beef curry", "গরুর মাংস", 250, 4.0, 22.0, 16.0, 0.5, None,
         {"bowl": 160, "piece": 80, "serving": 150}),
        ("Khichuri", "খিচুড়ি", 145, 24.0, 5.5, 3.0, 2.5, 65,
         {"bowl": 200, "cup": 160, "serving": 200}),
        ("Samosa", "সমুচা", 308, 32.0, 5.0, 17.0, 2.5, None,
         {"piece": 55, "serving": 55}),
        ("Sweet (roshogolla)", "রসগোল্লা", 186, 38.0, 4.0, 2.0, 0.0, None,
         {"piece": 45, "serving": 45}),
        ("Cucumber", "শসা", 15, 3.6, 0.7, 0.1, 0.5, 15,
         {"piece": 120, "cup": 120, "serving": 100}),
    ]

    op.execute(sa.text("""
        INSERT INTO food_items (
            id, region, name_en, name_local, kcal_per_100g, carbs_g_per_100g,
            protein_g_per_100g, fat_g_per_100g, fibre_g_per_100g,
            glycemic_index, portion_grams, source
        ) VALUES """ + ", ".join(
        "(gen_random_uuid(), 'bd', :n{i}, :l{i}, :k{i}, :c{i}, :p{i}, :f{i}, "
        ":fb{i}, :gi{i}, CAST(:pg{i} AS jsonb), 'placeholder')".format(i=i)
        for i in range(len(rows))
    )).bindparams(**{
        key: value
        for i, row in enumerate(rows)
        for key, value in {
            f"n{i}": row[0], f"l{i}": row[1], f"k{i}": row[2], f"c{i}": row[3],
            f"p{i}": row[4], f"f{i}": row[5], f"fb{i}": row[6], f"gi{i}": row[7],
            f"pg{i}": __import__("json").dumps(row[8]),
        }.items()
    }))


def downgrade() -> None:
    for table in ("reports", "coach_messages", "activity_logs", "daily_checkins",
                  "meal_log_items", "meal_logs", "food_items"):
        op.drop_table(table)
