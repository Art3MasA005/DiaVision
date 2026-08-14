"""Print the questions the app must ask, straight from the frozen contract.

The Flutter onboarding wizard, the API schema and the DB table are all built
against ml/contracts/feature_spec.json. This renders it in human form so the
three never drift apart — if a question appears here, the wizard asks it.

Usage:
    python ml/scripts/show_questions.py
    python ml/scripts/show_questions.py --tier 2     # include lab values
    python ml/scripts/show_questions.py --json       # machine-readable
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pipelines.contract import load_contract  # noqa: E402

WHY = {
    "age_years": "Risk rises with age. Under 18 the app is blocked entirely.",
    "sex_at_birth": "Waist thresholds and calorie floors differ by sex.",
    "height_cm": "Used to compute BMI and waist-to-height ratio.",
    "weight_kg": "Used to compute BMI. Also what changes when you act.",
    "waist_cm": "The strongest single measurement for South Asians. "
                "Belly fat predicts diabetes better than overall weight.",
    "family_history": "The strongest factor you cannot change.",
    "physical_activity": "Directly modifiable, and an IDRS input.",
    "smoker": "Raises insulin resistance.",
    "gestational_diabetes_history": "Diabetes in pregnancy raises later risk. Female profiles only.",
    "known_high_bp": "Scored by FINDRISC and ADA.",
    "on_bp_meds": "A FINDRISC input.",
    "history_high_glucose": "The heaviest single FINDRISC item (5 points).",
    "fasting_glucose_mmol_l": "From your own lab report. Unlocks the higher-confidence tier.",
    "hba1c_percent": "Three-month average blood sugar. The best single lab value.",
    "hdl_mmol_l": "Good cholesterol.",
    "triglycerides_mmol_l": "Blood fats.",
    "systolic_bp": "From your own monitor or a clinic reading.",
    "diastolic_bp": "From your own monitor or a clinic reading.",
}

HOW_TO_MEASURE = {
    "waist_cm": "Measure at the navel, standing, breathing out normally. "
                "Tape snug but not compressing. Not over clothing.",
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tier", type=int, default=1, choices=[1, 2])
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    contract = load_contract()
    asked = contract.asked_of_user(tier=args.tier)
    trains = set(contract.model_inputs(tier=args.tier))

    if args.json:
        print(json.dumps([{
            "name": f.name, "type": f.type, "tier": f.tier, "required": f.required,
            "values": list(f.values) if f.values else None, "range": list(f.range) if f.range else None,
            "unit": f.unit, "feeds_model": f.name in trains, "ui_key": f.ui_key,
        } for f in asked], indent=2))
        return 0

    print(f"\nFeature contract v{contract.version} ({contract.status})")
    print(f"Tier {args.tier} — {len(asked)} questions\n")

    required = [f for f in asked if f.required]
    optional = [f for f in asked if not f.required]

    def show(features, heading):
        if not features:
            return
        print(heading)
        print("=" * len(heading))
        for f in features:
            flag = "model" if f.name in trains else "score"
            print(f"\n  {f.name}    [{f.type}{'/' + f.unit if f.unit else ''}]  ({flag})")
            if f.values:
                print(f"    options : {' | '.join(f.values)}")
            if f.range:
                print(f"    range   : {f.range[0]} to {f.range[1]}")
            if WHY.get(f.name):
                print(f"    why     : {WHY[f.name]}")
            if HOW_TO_MEASURE.get(f.name):
                print(f"    how     : {HOW_TO_MEASURE[f.name]}")
        print()

    show(required, "REQUIRED")
    show(optional, "OPTIONAL")

    print("Legend")
    print("  (model)  feeds the machine-learning model AND the clinical score")
    print("  (score)  feeds ONLY the published clinical score — excluded from the")
    print("           model by the leakage audit. See docs/leakage_audit.md.")
    print()
    print(f"Derived automatically, never asked: "
          f"{', '.join(d.name for d in contract.derived)}")
    if args.tier == 1:
        print("\nLab values (fasting glucose, HbA1c, lipids, BP) are Tier 2 —")
        print("optional, and they unlock a narrower estimate. Run with --tier 2.")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
