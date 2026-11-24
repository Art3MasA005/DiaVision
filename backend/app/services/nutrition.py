"""Nutrition maths — PRD §F4, §F5, §5.4.

Three jobs, kept apart on purpose:

  portions       local unit -> grams, per food. A বাটি of ভাত is not a বাটি of
                 ডাল, so the conversion is per-food and never global.
  composition    grams -> kcal and macros, from the food's per-100g row.
  targets        a day's calorie target, ALWAYS through the §5.4 safety rails.

Everything here is a pure function over plain data. No database, no network —
so the safety-critical parts are testable against adversarial inputs, which
PRD §18 requires.

**Estimates are ranges.** `estimate_band` widens a computed figure by the
uncertainty its inputs actually carry, and the API returns the band rather than
a single number. A photo-recognised portion is not known to the calorie; saying
so is the honest presentation and the design asks for it explicitly.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from app.safety import ABSOLUTE, CalorieTarget, clamp_calorie_target

# Widths applied to a computed calorie figure. Manual entry with a weighed
# portion is tight; a photo-proposed portion is not.
UNCERTAINTY = {
    "weighed": 0.06,
    "manual": 0.14,
    "photo": 0.24,
}

# Fallback grams when a food carries no entry for the unit the user picked.
# Deliberately coarse — a wrong-but-flagged default beats refusing to log.
GENERIC_PORTION_GRAMS = {
    "cup": 150.0,
    "bowl": 200.0,
    "spoon": 15.0,
    "piece": 50.0,
    "slice": 30.0,
    "ladle": 80.0,
    "serving": 120.0,
    "g": 1.0,
    "gram": 1.0,
}


@dataclass
class Nutrients:
    kcal: float = 0.0
    carbs_g: float = 0.0
    protein_g: float = 0.0
    fat_g: float = 0.0
    fibre_g: float = 0.0
    glycemic_load: float | None = None

    def __add__(self, other: "Nutrients") -> "Nutrients":
        gl: float | None
        if self.glycemic_load is None and other.glycemic_load is None:
            gl = None
        else:
            gl = (self.glycemic_load or 0.0) + (other.glycemic_load or 0.0)
        return Nutrients(
            kcal=self.kcal + other.kcal,
            carbs_g=self.carbs_g + other.carbs_g,
            protein_g=self.protein_g + other.protein_g,
            fat_g=self.fat_g + other.fat_g,
            fibre_g=self.fibre_g + other.fibre_g,
            glycemic_load=gl,
        )

    def rounded(self) -> "Nutrients":
        return Nutrients(
            kcal=round(self.kcal),
            carbs_g=round(self.carbs_g, 1),
            protein_g=round(self.protein_g, 1),
            fat_g=round(self.fat_g, 1),
            fibre_g=round(self.fibre_g, 1),
            glycemic_load=None if self.glycemic_load is None
            else round(self.glycemic_load, 1),
        )


def grams_for(quantity: float, unit: str, portion_grams: dict | None) -> float:
    """Convert a local portion to grams for one specific food."""
    unit_key = (unit or "serving").strip().lower()
    per_unit = (portion_grams or {}).get(unit_key)
    if per_unit is None:
        per_unit = GENERIC_PORTION_GRAMS.get(unit_key, GENERIC_PORTION_GRAMS["serving"])
    return max(0.1, float(quantity) * float(per_unit))


def nutrients_for(grams: float, food: dict) -> Nutrients:
    """Scale a per-100g composition row to an actual portion.

    Glycemic load uses AVAILABLE carbohydrate — total carbs minus fibre — not
    total food weight. Fibre is carbohydrate the body does not turn into
    glucose, and counting it would overstate the load on exactly the foods
    (dal, vegetables, whole grains) this product wants to encourage.

    A food with no known GI gets `glycemic_load = None`. A guessed GL on a
    diabetes app is worse than an absent one.
    """
    factor = grams / 100.0
    carbs = float(food.get("carbs_g_per_100g") or 0.0) * factor
    fibre = float(food.get("fibre_g_per_100g") or 0.0) * factor

    gi = food.get("glycemic_index")
    load: float | None = None
    if gi is not None:
        available_carbs = max(0.0, carbs - fibre)
        load = float(gi) * available_carbs / 100.0

    return Nutrients(
        kcal=float(food.get("kcal_per_100g") or 0.0) * factor,
        carbs_g=carbs,
        protein_g=float(food.get("protein_g_per_100g") or 0.0) * factor,
        fat_g=float(food.get("fat_g_per_100g") or 0.0) * factor,
        fibre_g=fibre,
        glycemic_load=load,
    )


def estimate_band(kcal: float, method: str = "manual") -> tuple[int, int]:
    """A calorie figure as the range it honestly is.

    Rule 1 of the shipping rules is about risk, but the same reasoning applies
    here: a single number implies a precision that a photograph of a plate of
    rice does not have.
    """
    width = UNCERTAINTY.get(method, UNCERTAINTY["manual"])
    return int(round(kcal * (1 - width))), int(round(kcal * (1 + width)))


# ── daily targets ─────────────────────────────────────────────────────

def mifflin_st_jeor(sex: str, weight_kg: float, height_cm: float, age: int) -> float:
    """Resting metabolic rate. Mifflin-St Jeor — the usual clinical default."""
    base = 10 * weight_kg + 6.25 * height_cm - 5 * age
    return base + (5 if sex == "male" else -161)


# The goal sheet's range.
GOAL_MIN_KCAL = 1200
GOAL_MAX_KCAL = 3500

# A day's glycemic-load aim, shown as a marker on the tracker's GL bar.
GL_DAILY_AIM = 80

ACTIVITY_FACTORS = {
    "sedentary": 1.2,
    "light": 1.375,
    "moderate": 1.55,
    "active": 1.725,
    "very_active": 1.9,
}


@dataclass
class DailyTarget:
    kcal: int
    carbs_g: int
    protein_g: int
    fat_g: int
    fibre_g: int
    glycemic_load_ceiling: int
    maintenance_kcal: int
    was_clamped: bool = False
    clamp_reason: str | None = None
    weight_loss_disabled: bool = False
    notes: list[str] = field(default_factory=list)


def daily_target(
    *,
    sex: str,
    weight_kg: float,
    height_cm: float,
    age: int,
    activity: str = "sedentary",
    goal: str = "maintain",
    bmi: float | None = None,
    requested_kcal: int | None = None,
) -> DailyTarget:
    """A day's targets, already through the §5.4 rails.

    The rails are not advisory. `clamp_calorie_target` is the only path to a
    kcal figure here, so a deficit this function could otherwise produce cannot
    escape the floor — PRD §3.6: "A wrong number typed once shouldn't be able
    to starve a patient."
    """
    rmr = mifflin_st_jeor(sex, weight_kg, height_cm, age)
    maintenance = rmr * ACTIVITY_FACTORS.get(activity, 1.2)

    # The user's own goal from the goal sheet, when set, replaces the computed
    # one — but it is still a request. It goes through the same rails below,
    # and the goal sheet's own range (1,200–3,500) caps it from above.
    if requested_kcal is not None:
        requested = float(min(max(requested_kcal, 1200), GOAL_MAX_KCAL))
    else:
        requested = maintenance - (400 if goal == "lose" else 0)
    clamped: CalorieTarget = clamp_calorie_target(
        requested_kcal=requested, sex=sex, tdee=maintenance, bmi=bmi
    )
    kcal = clamped.kcal

    # A moderate-carb split. Not a low-carb prescription: this is a screening
    # and lifestyle product, and prescribing macros for someone who may have
    # undetected high blood sugar is a doctor's job.
    carbs_g = int(round(kcal * 0.45 / 4))
    protein_g = int(round(kcal * 0.20 / 4))
    fat_g = int(round(kcal * 0.35 / 9))

    notes: list[str] = []
    if clamped.weight_loss_disabled:
        notes.append("Weight-loss targets are off; this is a maintenance day.")

    return DailyTarget(
        kcal=kcal,
        carbs_g=carbs_g,
        protein_g=protein_g,
        fat_g=fat_g,
        # 25–30g is the usual adult recommendation; scale gently with intake.
        fibre_g=max(25, int(round(kcal / 1000 * 14))),
        # The design's "aim to keep it under 80 a day". Presented as guidance
        # and never as a pass/fail — the copy names the next smaller portion.
        glycemic_load_ceiling=GL_DAILY_AIM,
        maintenance_kcal=int(round(maintenance)),
        was_clamped=clamped.was_clamped,
        clamp_reason=clamped.reason,
        weight_loss_disabled=clamped.weight_loss_disabled,
        notes=notes,
    )


def bmi_for(weight_kg: float | None, height_cm: float | None) -> float | None:
    if not weight_kg or not height_cm:
        return None
    metres = height_cm / 100.0
    if metres <= 0:
        return None
    return weight_kg / (metres * metres)


__all__ = [
    "ABSOLUTE",
    "DailyTarget",
    "Nutrients",
    "bmi_for",
    "daily_target",
    "estimate_band",
    "grams_for",
    "nutrients_for",
]
