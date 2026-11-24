"""Tracker: water, favourite foods, a user calorie goal, food aliases.

Revision ID: 0004
Revises: 0003
Create Date: 2026-11-24

What the redesigned calorie tracker and the Add food screen need:

  * `water_logs`      glasses per day (8 × 250 ml by default), behind RLS
  * `food_favourites` foods the user starred, behind RLS
  * `health_profiles.kcal_goal`  the goal sheet's value. Still a request: it
    goes through the §5.4 rails like every other calorie target
  * `food_items.aliases`  transliterations and other spellings, so a search
    for "murgir jhol" or "bhat" finds the row

More starter foods are added. Like the 0003 seed they are widely-published
approximations marked `source='placeholder'`, NOT the Bangladesh food
composition table (which `packs/bd.json` records as `permission_pending`).
Glycemic index is left NULL where no widely-agreed value exists.
"""
from __future__ import annotations

import json
from pathlib import Path
from typing import Sequence

import sqlalchemy as sa
from alembic import op

import sys as _sys
_sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from app.db.migration_guards import Guarded  # noqa: E402
from sqlalchemy.dialects import postgresql

revision: str = "0004"
down_revision: str | None = "0003"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

RLS_SQL = Path(__file__).resolve().parents[2] / "app" / "db" / "rls.sql"
_UUID = postgresql.UUID(as_uuid=True)

# name_en of an existing row -> aliases
ALIASES = {
    "Boiled rice": "bhat rice plain rice sada bhat white rice",
    "Roti (wheat)": "ruti roti chapati atta",
    "Paratha": "porota parota paratha",
    "Lentil dal": "dal daal dhal masoor musur lentil",
    "Fish curry": "macher jhol mach jhol fish jhol machh",
    "Chicken curry": "murgir jhol murgi chicken jhol murgir mangsho",
    "Egg, boiled": "dim siddho dim boiled egg egg",
    "Mixed vegetables": "sobji shobji torkari vegetable sabzi",
    "Potato, boiled": "alu aloo potato",
    "Puffed rice": "muri moori puffed rice",
    "Banana": "kola kela banana",
    "Mango": "aam am mango",
    "Milk tea with sugar": "dudh cha cha chai milk tea",
    "Tea without sugar": "chini chara cha lal cha black tea red tea",
    "Yoghurt, plain": "tok doi doi yogurt curd",
    "Beef curry": "gorur mangsho goru beef",
    "Khichuri": "khichuri khichdi",
    "Samosa": "somucha samucha samosa",
    "Sweet (roshogolla)": "roshogolla rasgulla rosogolla mishti",
    "Cucumber": "shosha sosha cucumber",
}

# name_en, name_local, kcal, carbs, protein, fat, fibre, GI, portions, aliases
NEW_FOODS = [
    ("Chicken biryani", "বিরিয়ানি", 190, 23.0, 9.0, 7.0, 1.0, None,
     {"plate": 300, "cup": 160, "serving": 300}, "biriyani biryani kacchi"),
    ("Polao", "পোলাও", 180, 28.0, 3.0, 6.0, 0.8, None,
     {"plate": 250, "cup": 150, "serving": 200}, "polao pulao pilaf"),
    ("Mashed potato bhorta", "আলু ভর্তা", 120, 17.0, 2.0, 5.0, 2.0, None,
     {"spoon": 25, "bowl": 120, "serving": 80}, "alu bhorta aloo bharta bhorta"),
    ("Fried aubergine", "বেগুন ভাজা", 150, 8.0, 1.5, 12.0, 3.0, None,
     {"piece": 40, "serving": 80}, "begun bhaja brinjal eggplant"),
    ("Leafy greens, cooked", "শাক", 60, 6.0, 3.0, 3.0, 3.0, None,
     {"bowl": 120, "cup": 100, "serving": 100}, "shak sak lal shak palong spinach"),
    ("Hilsa fish curry", "ইলিশ মাছ", 250, 3.0, 20.0, 18.0, 0.3, None,
     {"piece": 90, "bowl": 180, "serving": 120}, "ilish hilsa shorshe ilish"),
    ("Fried fish", "মাছ ভাজা", 220, 6.0, 20.0, 13.0, 0.3, None,
     {"piece": 70, "serving": 70}, "mach bhaja fish fry"),
    ("Omelette", "ডিম ভাজা", 196, 1.0, 13.0, 15.0, 0.0, None,
     {"piece": 60, "serving": 60}, "dim bhaja omelette omlet fried egg"),
    ("Chickpea curry", "ছোলা", 160, 25.0, 8.0, 3.0, 7.0, 28,
     {"bowl": 150, "cup": 140, "serving": 150}, "chola chhola chana chickpea"),
    ("Haleem", "হালিম", 140, 14.0, 9.0, 5.0, 3.0, None,
     {"bowl": 250, "serving": 250}, "halim haleem"),
    ("White bread", "পাউরুটি", 265, 49.0, 9.0, 3.2, 2.7, 75,
     {"slice": 30, "piece": 30, "serving": 60}, "pauruti bread toast"),
    ("Milk", "দুধ", 64, 4.8, 3.3, 3.6, 0.0, 31,
     {"cup": 200, "serving": 200}, "dudh milk"),
    ("Sugar", "চিনি", 400, 100.0, 0.0, 0.0, 0.0, 65,
     {"spoon": 5, "serving": 5}, "chini sugar"),
    ("Dates", "খেজুর", 282, 75.0, 2.5, 0.4, 8.0, 42,
     {"piece": 8, "serving": 24}, "khejur dates"),
    ("Guava", "পেয়ারা", 68, 14.0, 2.6, 1.0, 5.4, 31,
     {"piece": 150, "serving": 150}, "peyara guava"),
    ("Apple", "আপেল", 52, 14.0, 0.3, 0.2, 2.4, 36,
     {"piece": 180, "serving": 180}, "apel apple"),
    ("Jilapi", "জিলাপি", 380, 60.0, 3.0, 15.0, 0.5, None,
     {"piece": 30, "serving": 60}, "jilapi jalebi"),
    ("Singara", "সিঙ্গারা", 300, 32.0, 5.0, 17.0, 2.5, None,
     {"piece": 60, "serving": 60}, "singara shingara"),
    ("Payesh", "পায়েস", 160, 25.0, 4.0, 5.0, 0.3, None,
     {"bowl": 150, "cup": 130, "serving": 130}, "payesh kheer rice pudding"),
    ("Biscuit", "বিস্কুট", 450, 70.0, 7.0, 16.0, 2.0, None,
     {"piece": 8, "serving": 30}, "biskut biscuit cookie"),
]


def _profile_fk() -> sa.Column:
    return sa.Column("profile_id", _UUID,
                     sa.ForeignKey("profiles.id", ondelete="CASCADE"), nullable=False)


def upgrade() -> None:
    # Guarded: on a fresh database 0001 already built these from the models.
    # See app/db/migration_guards.py.
    g = Guarded(op)
    g.create_table(
        "water_logs",
        sa.Column("id", _UUID, primary_key=True),
        _profile_fk(),
        sa.Column("logged_on", sa.Date, nullable=False),
        sa.Column("glasses", sa.Integer, nullable=False, server_default="0"),
        sa.Column("ml_per_glass", sa.Integer, nullable=False, server_default="250"),
        sa.Column("updated_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.CheckConstraint("glasses BETWEEN 0 AND 30", name="ck_water_glasses"),
        sa.CheckConstraint("ml_per_glass BETWEEN 50 AND 1000", name="ck_water_ml"),
        sa.UniqueConstraint("profile_id", "logged_on", name="uq_water_profile_day"),
    )
    g.create_index("ix_water_logs_profile_id", "water_logs", ["profile_id"])

    g.create_table(
        "food_favourites",
        sa.Column("id", _UUID, primary_key=True),
        _profile_fk(),
        sa.Column("food_id", _UUID,
                  sa.ForeignKey("food_items.id", ondelete="CASCADE"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True),
                  server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("profile_id", "food_id", name="uq_favourite_profile_food"),
    )
    g.create_index("ix_food_favourites_profile_id", "food_favourites", ["profile_id"])

    g.add_column("health_profiles", sa.Column("kcal_goal", sa.Integer))
    g.create_check_constraint(
        "ck_health_kcal_goal", "health_profiles",
        "kcal_goal IS NULL OR kcal_goal BETWEEN 1200 AND 3500")

    g.add_column("food_items", sa.Column("aliases", sa.Text, nullable=False,
                                          server_default=""))
    for name, aliases in ALIASES.items():
        op.execute(sa.text(
            "UPDATE food_items SET aliases = :a WHERE name_en = :n AND region = 'bd'"
        ).bindparams(a=aliases, n=name))

    for row in NEW_FOODS:
        (name, local, kcal, carbs, protein, fat, fibre, gi, portions, aliases) = row
        op.execute(sa.text("""
            INSERT INTO food_items (
                id, region, name_en, name_local, kcal_per_100g, carbs_g_per_100g,
                protein_g_per_100g, fat_g_per_100g, fibre_g_per_100g,
                glycemic_index, portion_grams, aliases, source
            )
            SELECT gen_random_uuid(), 'bd', :n, :l, :k, :c, :p, :f, :fb, :gi,
                   CAST(:pg AS jsonb), :al, 'placeholder'
            WHERE NOT EXISTS (
                SELECT 1 FROM food_items WHERE region = 'bd' AND name_en = :n)
        """).bindparams(n=name, l=local, k=kcal, c=carbs, p=protein, f=fat,
                        fb=fibre, gi=gi, pg=json.dumps(portions), al=aliases))

    # Applies RLS to the two new profile-scoped tables. Idempotent.
    op.execute(sa.text(RLS_SQL.read_text(encoding="utf-8")))


def downgrade() -> None:
    op.execute(sa.text(
        "DELETE FROM food_items WHERE source = 'placeholder' AND name_en = ANY(:names)"
    ).bindparams(names=[r[0] for r in NEW_FOODS]))
    op.drop_column("food_items", "aliases")
    op.drop_constraint("ck_health_kcal_goal", "health_profiles", type_="check")
    op.drop_column("health_profiles", "kcal_goal")
    op.drop_table("food_favourites")
    op.drop_table("water_logs")
