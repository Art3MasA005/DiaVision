"""Run the PRD personas through the Layer-1 clinical score and print the result.

A quick way to see what the risk model actually produces, and a sanity check
that the scores behave sensibly on realistic people rather than only on the
synthetic edge cases in the test suite.

This is Layer 1 ONLY — the transparent published score. The gradient-boosted
model (Layer 2) is not trained yet, so what you see here is exactly what the
app would show in a market with validation_status = 'not_validated': the
clinical score alone, honestly labelled.

Usage:
    python ml/scripts/demo_risk.py
    python ml/scripts/demo_risk.py --region gb
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pipelines.clinical_scores import Subject, score_for_region  # noqa: E402

# PRD §4 personas, given plausible measurements.
PERSONAS = [
    ("Ashraf, 44 — worried but undiagnosed (Persona 1)",
     "Bank officer in Dhaka. Father had diabetes. Belly fat, desk job, never tested.",
     Subject(age_years=44, sex_at_birth="male", height_cm=172, weight_kg=82,
             waist_cm=102, family_history="first_degree",
             physical_activity="sedentary", smoker=False)),

    ("Nasrin, 52 — newly diagnosed T2D (Persona 2)",
     "Diagnosed 6 months ago, on metformin. Wants daily plate guidance.",
     Subject(age_years=52, sex_at_birth="female", height_cm=155, weight_kg=68,
             waist_cm=94, family_history="first_degree",
             physical_activity="light", known_high_bp=True,
             history_high_glucose=True)),

    ("Tanvir, 29 — prediabetic, gym-curious (Persona 3)",
     "Wants a step counter and to lose 8kg.",
     Subject(age_years=29, sex_at_birth="male", height_cm=175, weight_kg=88,
             waist_cm=95, family_history="second_degree",
             physical_activity="moderate")),

    ("Rukhsana, 31 — low risk control case",
     "Not a PRD persona. Included so we can see the score go DOWN.",
     Subject(age_years=31, sex_at_birth="female", height_cm=162, weight_kg=54,
             waist_cm=71, family_history="none",
             physical_activity="very_active")),
]

BANDS = {
    "low": "LOW", "slightly_elevated": "SLIGHTLY ELEVATED", "moderate": "MODERATE",
    "high": "HIGH", "very_high": "VERY HIGH",
}


def show(title: str, blurb: str, s: Subject, region: str) -> None:
    r = score_for_region(s, region)
    w2h = s.waist_to_height_ratio

    print("=" * 72)
    print(title)
    print(f"  {blurb}")
    print()
    print(f"  age {s.age_years}  ·  {s.sex_at_birth}  ·  {s.height_cm:.0f} cm  ·  "
          f"{s.weight_kg:.0f} kg  ·  waist {s.waist_cm:.0f} cm")
    print(f"  BMI {s.bmi:.1f}" + (f"  ·  waist-to-height {w2h:.2f}" if w2h else ""))
    print()
    print(f"  {r.score}:  {r.points} / {r.max_points}   →   {BANDS.get(r.band, r.band)}")
    print(f"  {r.interpretation}")
    print()
    print("  What drove it:")
    for item in r.top_factors(3):
        print(f"    +{item.points:<4} {item.label}")
    zero = [i for i in r.items if i.points == 0]
    if zero:
        print(f"    (no points from: {', '.join(i.label.lower() for i in zero)})")
    if r.caveats:
        print()
        print("  Caveats:")
        for c in r.caveats:
            print(f"    · {c}")
    print()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--region", default="bd", help="region code (default: bd)")
    args = parser.parse_args()

    print()
    print(f"Layer-1 clinical score · region = {args.region.upper()}")
    print("Layer-2 GBM not trained yet — this is what a 'not_validated' market shows.")
    print()

    for title, blurb, subject in PERSONAS:
        show(title, blurb, subject, args.region)

    print("=" * 72)
    print("Reminder: this is a risk ESTIMATE, not a diagnosis. Only a blood test")
    print("ordered by a doctor can confirm diabetes. (PRD §3.2)")
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
