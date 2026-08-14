"""Risk assessment service — bridges the API to the trained model.

The model runs IN-PROCESS. There is no HTTP hop to a separate ML service:
`/risk/assess` must render in under 2 seconds (PRD §F2) and a network round
trip to buy nothing would be a strange way to spend that budget.

Routing follows PRD §7.4b. Where a market's model is not validated, the
transparent clinical score answers and the response says so — rather than a
gradient booster quietly guessing on a population it has never seen.
"""

from __future__ import annotations

import sys
from datetime import date
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO_ROOT / "ml"))

from pipelines import predict as risk_engine  # noqa: E402


def health_profile_to_record(health: Any, age_years: int | None = None) -> dict[str, Any]:
    """Map a HealthProfile row to the contract's feature vocabulary."""
    age = age_years
    if age is None and getattr(health, "dob", None):
        today = date.today()
        dob: date = health.dob
        age = today.year - dob.year - ((today.month, today.day) < (dob.month, dob.day))

    return {
        "age_years": age,
        "sex_at_birth": health.sex_at_birth,
        "height_cm": health.height_cm,
        "weight_kg": health.weight_kg,
        "waist_cm": health.waist_cm,
        "family_history": health.family_history or "none",
        "physical_activity": health.physical_activity or "sedentary",
        "smoker": bool(health.smoker),
        "known_high_bp": bool(health.known_high_bp),
        "on_bp_meds": bool(health.on_bp_meds),
        "history_high_glucose": bool(health.history_high_glucose),
        "gestational_diabetes_history": health.gestational_diabetes_history,
    }


def assess(record: dict[str, Any], region: str) -> dict[str, Any]:
    """Run the model. Raises ValueError on an invalid record."""
    result = risk_engine.predict(record, region=region)
    return result.to_dict()


def region_pack(region: str) -> dict[str, Any]:
    return risk_engine.load_pack(region)


def should_route_to_management(diabetes_status: str | None) -> bool:
    """Whether this user should see management mode instead of a risk screen.

    PRD §F1: `diabetes_status` "routes the whole app experience". Showing a
    screening estimate to someone already diagnosed is a category error — the
    question "might you have diabetes?" is already answered, and re-asking it
    is at best noise and at worst distressing.
    """
    return (diabetes_status or "no").lower() in ("t2d", "t1d", "gestational")
