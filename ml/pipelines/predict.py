"""Inference: user attributes in, calibrated risk percentage out.

This is what sits behind `POST /risk/assess` (PRD §10) and what the Flutter
result screen renders. The shape of the output is dictated by PRD §F2, and
every part of it is required rather than decorative:

  band            — the headline. Bands are more honest than a fake-precise %.
  probability     — the calibrated number. 20% must mean 20 in 100.
  range           — never a point value (PRD §5, principle 1).
  top_factors     — split modifiable vs not, so the user is not demoralised
                    by age and family history they cannot change.
  tier            — which model answered, so the UI can say what it was based on.
  validation_status — honest per-market state (PRD §7.4b). Where the model is
                    not validated, the clinical score answers instead.
  disclaimer      — never optional. PRD §3.2.

Usage:
    python ml/pipelines/predict.py --demo
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pipelines.clinical_scores import Subject, score_for_region  # noqa: E402
from pipelines.contract import add_derived, load_contract  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = REPO_ROOT / "ml" / "artifacts"
PACKS = REPO_ROOT / "packs"

DISCLAIMER = ("This is a statistical estimate, not a diagnosis. Only a blood test "
              "ordered by a doctor can confirm diabetes.")

# PRD §F2 — bands are the headline; the percentage is supporting detail.
BANDS = [
    (0.00, 0.08, "low", "Low"),
    (0.08, 0.20, "moderate", "Moderate"),
    (0.20, 0.40, "high", "High"),
    (0.40, 1.01, "very_high", "Very High"),
]


@dataclass
class Factor:
    label: str
    points: int
    modifiable: bool
    detail: str = ""


@dataclass
class RiskResult:
    band: str
    band_label: str
    probability: float
    range_low: float
    range_high: float
    tier: int
    basis: str
    validation_status: str
    region: str
    model_version: str
    clinical_score: str
    clinical_points: int
    clinical_max: int
    modifiable_factors: list[Factor] = field(default_factory=list)
    fixed_factors: list[Factor] = field(default_factory=list)
    caveats: list[str] = field(default_factory=list)
    disclaimer: str = DISCLAIMER

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _band(p: float) -> tuple[str, str]:
    for lo, hi, key, label in BANDS:
        if lo <= p < hi:
            return key, label
    return "very_high", "Very High"


def _subject(record: dict[str, Any]) -> Subject:
    return Subject(
        age_years=int(record["age_years"]),
        sex_at_birth=record["sex_at_birth"],
        height_cm=float(record["height_cm"]),
        weight_kg=float(record["weight_kg"]),
        waist_cm=None if record.get("waist_cm") is None else float(record["waist_cm"]),
        family_history=record.get("family_history", "none"),
        physical_activity=record.get("physical_activity", "sedentary"),
        smoker=bool(record.get("smoker", False)),
        known_high_bp=bool(record.get("known_high_bp", False)),
        on_bp_meds=bool(record.get("on_bp_meds", False)),
        history_high_glucose=bool(record.get("history_high_glucose", False)),
        gestational_diabetes_history=record.get("gestational_diabetes_history"),
    )


def load_pack(region: str) -> dict[str, Any]:
    path = PACKS / f"{region.lower()}.json"
    if not path.exists():
        raise FileNotFoundError(f"No region pack for {region!r}. Available: "
                                f"{sorted(p.stem for p in PACKS.glob('*.json') if not p.stem.startswith('_'))}")
    return json.loads(path.read_text(encoding="utf-8"))


def load_model(tag: str = "synthetic"):
    path = ARTIFACTS / f"model_a_{tag}.joblib"
    if not path.exists():
        return None
    import joblib
    return joblib.load(path)


# Non-modifiable factors go in their own section so the result screen does not
# read as a list of personal failings (PRD §F2).
NON_MODIFIABLE_KEYS = {"age", "family", "sex", "gestational"}


def predict(record: dict[str, Any], region: str = "bd", model_tag: str = "v1"
            ) -> RiskResult:
    """Estimate risk for one person.

    Routing follows PRD §7.4b: where the market's model is not validated, the
    transparent clinical score answers and says so, rather than a GBM quietly
    guessing on a population it has never seen.
    """
    contract = load_contract()
    problems = contract.validate(record, tier=1)
    if problems:
        raise ValueError("Invalid record: " + "; ".join(problems))

    pack = load_pack(region)
    model_cfg = pack["risk_model"]
    validation_status = model_cfg["validation_status"]

    subject = _subject(record)
    clinical = score_for_region(subject, region, score=model_cfg.get("clinical_score"))

    factors = [
        Factor(label=i.label, points=i.points,
               modifiable=i.key not in NON_MODIFIABLE_KEYS, detail=i.detail)
        for i in clinical.items if i.points > 0
    ]
    modifiable = sorted([f for f in factors if f.modifiable], key=lambda f: -f.points)
    fixed = sorted([f for f in factors if not f.modifiable], key=lambda f: -f.points)

    bundle = load_model(model_tag)
    use_model = bundle is not None and validation_status in ("validated", "provisional")

    if use_model:
        enriched = add_derived(record)
        row = pd.DataFrame([enriched])
        X = row.reindex(columns=bundle["numeric"] + bundle["categorical"])
        for col in bundle["categorical"]:
            X[col] = X[col].astype("category")
        p_gbm = float(bundle["isotonic_gbm"].predict(bundle["gbm"].predict_proba(X)[:, 1])[0])
        p_clin = float(bundle["isotonic_clinical"].predict(np.array([clinical.fraction]))[0])
        w = bundle["blend_weight_gbm"]
        probability = w * p_gbm + (1 - w) * p_clin
        tier, basis = 1, "your answers, scored by our model blended with a published clinical score"
        model_version = f"model_a_{model_tag}@{bundle['contract_version']}"
        caveats = list(clinical.caveats)
    else:
        # Degrade honestly. The clinical score is a published instrument, so
        # this is a real answer — just a less precise one.
        probability = _clinical_to_probability(clinical.fraction, model_cfg)
        tier, basis = 1, f"your answers, scored using the published {clinical.score} instrument"
        model_version = f"clinical_only:{clinical.score.lower()}"
        caveats = [
            f"Our model is not yet validated for {pack['country']}, so this estimate uses "
            f"the published {clinical.score} score alone. It is transparent and validated, "
            f"but less precise than a locally-calibrated model.",
            *clinical.caveats,
        ]

    band, band_label = _band(probability)
    # Width reflects genuine uncertainty: wider when no local model exists.
    half = 0.05 if use_model else 0.08
    return RiskResult(
        band=band, band_label=band_label,
        probability=round(probability, 4),
        range_low=round(max(0.0, probability - half), 4),
        range_high=round(min(1.0, probability + half), 4),
        tier=tier, basis=basis,
        validation_status=validation_status,
        region=region.lower(),
        model_version=model_version,
        clinical_score=clinical.score,
        clinical_points=clinical.points,
        clinical_max=clinical.max_points,
        modifiable_factors=modifiable,
        fixed_factors=fixed,
        caveats=caveats,
    )


def _clinical_to_probability(fraction: float, model_cfg: dict[str, Any]) -> float:
    """Map a clinical score fraction to a probability, anchored on prevalence.

    Deliberately crude and deliberately conservative. A published score gives
    a risk *stratum*, not a probability, and inventing a precise-looking curve
    for a market we have never validated would be exactly the false precision
    PRD §5 forbids. Where a verified prevalence prior exists we centre on it;
    where it does not we centre on a neutral 12%, which is roughly the middle
    of global adult prevalence estimates and is stated as an assumption.
    """
    prior_cfg = model_cfg.get("prevalence_prior") or {}
    prior = prior_cfg.get("value") if prior_cfg.get("source_verified") else None
    base = prior if prior is not None else 0.12
    # Score fraction 0 -> a third of base; 1 -> roughly 3x base, capped.
    multiplier = 0.33 + 2.7 * fraction
    return float(min(0.95, base * multiplier))


# ──────────────────────────────────────────────────────────────────────
# Demo
# ──────────────────────────────────────────────────────────────────────

# PRD §4 Persona 1 — Ashraf, 44, Dhaka bank officer. Father had diabetes,
# desk job, belly fat, has never had a fasting glucose test.
#
# Note the last three fields. They are held out of the GBM pending the leakage
# audit, but the app still ASKS for them because FINDRISC and ADA score them.
# Ashraf answers "no" to all three — not because he is healthy, but because
# nobody has ever tested him. That is precisely the user this product exists
# for, and precisely why those features are leakage suspects.
DEMO = {
    "age_years": 44, "sex_at_birth": "male", "height_cm": 172.0,
    "weight_kg": 82.0, "waist_cm": 102.0, "family_history": "first_degree",
    "physical_activity": "sedentary", "smoker": False,
    "known_high_bp": False, "on_bp_meds": False, "history_high_glucose": False,
}


def render(r: RiskResult) -> str:
    width = 60
    pct = f"{r.probability * 100:.0f}%"
    lo, hi = f"{r.range_low * 100:.0f}%", f"{r.range_high * 100:.0f}%"
    headline = f"Estimated risk: {lo}–{hi}  (about {pct})"

    def row(text: str) -> str:
        # Border is 1 + width + 1. Row is 1 + 2 (indent) + pad + 1, so pad
        # must be width - 2 for the columns to line up.
        return "│  " + text.ljust(width - 2) + "│"

    lines = [
        "┌" + "─" * width + "┐",
        row(r.band_label.upper()),
        row(headline),
        "└" + "─" * width + "┘",
        "",
        f"  Based on: {r.basis}",
        f"  {r.clinical_score} score: {r.clinical_points}/{r.clinical_max}"
        f"   ·   region {r.region.upper()}   ·   {r.validation_status}",
        f"  model: {r.model_version}",
        "",
    ]
    if r.modifiable_factors:
        lines.append("  What you can change:")
        for f in r.modifiable_factors:
            lines.append(f"    +{f.points:<4} {f.label}")
        lines.append("")
    if r.fixed_factors:
        lines.append("  What you cannot change (not your fault):")
        for f in r.fixed_factors:
            lines.append(f"    +{f.points:<4} {f.label}")
        lines.append("")
    if r.caveats:
        lines.append("  Caveats:")
        for c in r.caveats:
            lines.append(f"    · {c}")
        lines.append("")
    lines.append(f"  {r.disclaimer}")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--demo", action="store_true")
    parser.add_argument("--region", default="bd")
    parser.add_argument("--json", action="store_true", help="print the API payload")
    args = parser.parse_args()

    result = predict(DEMO, region=args.region)
    if args.json:
        print(json.dumps(result.to_dict(), indent=2))
    else:
        print()
        print(f"Input: {DEMO}")
        print()
        print(render(result))
        print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
