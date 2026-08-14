"""Validate every region pack. Run in CI — a bad pack is a shipped safety bug.

Schema conformance is the easy half. The checks that matter are the ones a
JSON Schema cannot express:

  * A pack may make a safety threshold STRICTER, never looser. Region config is
    a localisation mechanism, not a way to route around PRD §5.4.
  * Clinician mode must be off in the EU/UK without a Notified Body engagement
    (PRD §3.5). Left to reviewer diligence this WILL eventually ship enabled.
  * Regulated markets must use the 'metabolic_health_score' wording, because
    MDR Rule 11 catches prediction/prognosis claims.
  * The pack's clinical_score must agree with the routing table the ML side
    uses, or the model and the app disagree about which instrument anchors
    a market.

Exit codes: 0 all valid · 1 at least one ERROR · 0 with warnings only.

Usage:
    python ml/scripts/validate_packs.py
    python ml/scripts/validate_packs.py --strict   # warnings become errors
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PACKS = REPO_ROOT / "packs"
SCHEMA = PACKS / "_schema.json"

sys.path.insert(0, str(REPO_ROOT / "ml"))
from pipelines.clinical_scores import DEFAULT_SCORE_BY_REGION  # noqa: E402

# PRD §5.4 / §3.3. These are absolute. A pack may go stricter, never looser.
ABSOLUTE_FLOORS = {
    "min_daily_kcal.female": (1200, "min"),
    "min_daily_kcal.male": (1500, "min"),
    "max_daily_deficit_kcal": (500, "max"),
    "max_weight_loss_kg_per_week": (1.0, "max"),
    "bmi_floor_disable_weight_loss": (18.5, "min"),
    "disordered_eating_kcal_floor": (800, "min"),
    "min_age": (18, "min"),
    "glucose_mmol_l.hypoglycaemia": (3.9, "max"),
    "glucose_mmol_l.fasting_urgent": (13.9, "max"),
    "glucose_mmol_l.random_urgent": (16.7, "max"),
}

# Markets where clinician mode is legally gated (PRD §3.5).
CLINICIAN_MODE_FORBIDDEN = {
    "de", "fr", "it", "es", "nl", "be", "at", "ie", "pt", "pl", "se", "dk", "fi",
    "gb",
}
REGULATED_WORDING = CLINICIAN_MODE_FORBIDDEN


def _dig(obj: dict, dotted: str):
    for part in dotted.split("."):
        if not isinstance(obj, dict) or part not in obj:
            return None
        obj = obj[part]
    return obj


class Report:
    def __init__(self) -> None:
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def error(self, pack: str, msg: str) -> None:
        self.errors.append(f"{pack}: {msg}")

    def warn(self, pack: str, msg: str) -> None:
        self.warnings.append(f"{pack}: {msg}")


def check_schema(pack: dict, name: str, schema: dict, rep: Report) -> None:
    try:
        import jsonschema
    except ImportError:
        rep.warn(name, "jsonschema not installed — structural validation skipped "
                       "(pip install jsonschema)")
        return
    validator = jsonschema.Draft7Validator(schema)
    for err in sorted(validator.iter_errors(pack), key=lambda e: list(e.path)):
        where = ".".join(str(p) for p in err.path) or "<root>"
        rep.error(name, f"schema: {where}: {err.message}")


def check_safety_floors(pack: dict, name: str, rep: Report) -> None:
    thresholds = pack.get("safety_thresholds", {})
    for path, (limit, direction) in ABSOLUTE_FLOORS.items():
        value = _dig(thresholds, path)
        if value is None:
            rep.error(name, f"safety_thresholds.{path} is missing")
            continue
        if direction == "min" and value < limit:
            rep.error(name, f"safety_thresholds.{path} = {value} is LOOSER than the "
                            f"absolute floor {limit}. A region pack may go stricter, never looser.")
        if direction == "max" and value > limit:
            rep.error(name, f"safety_thresholds.{path} = {value} is LOOSER than the "
                            f"absolute ceiling {limit}. A region pack may go stricter, never looser.")
    if not str(thresholds.get("emergency_number", "")).strip():
        rep.error(name, "emergency_number is empty — PRD §18 requires it per market before launch")


def check_regulatory(pack: dict, name: str, rep: Report) -> None:
    code = pack.get("code", name)
    features = pack.get("features", {})
    regulatory = pack.get("regulatory", {})

    if code in CLINICIAN_MODE_FORBIDDEN and features.get("clinician_mode_enabled"):
        rep.error(name, "clinician_mode_enabled is TRUE in a market that requires a "
                        "Notified Body / UKCA assessment first (PRD §3.5).")

    wording = regulatory.get("risk_wording")
    if code in REGULATED_WORDING and wording != "metabolic_health_score":
        rep.error(name, f"risk_wording is {wording!r}; regulated markets must use "
                        "'metabolic_health_score' — MDR Rule 11 catches prediction claims.")

    if regulatory.get("intended_purpose") == "medical_device":
        rep.warn(name, "intended_purpose is 'medical_device' — this pack asserts we ARE "
                       "a regulated device here. Confirm the conformity route exists.")


def check_model_readiness(pack: dict, name: str, rep: Report) -> None:
    code = pack.get("code", name)
    model = pack.get("risk_model", {})

    expected = DEFAULT_SCORE_BY_REGION.get(code)
    actual = model.get("clinical_score")
    if expected and actual != expected:
        rep.error(name, f"clinical_score {actual!r} disagrees with the ML routing table "
                        f"({expected!r}) in clinical_scores.DEFAULT_SCORE_BY_REGION.")
    elif not expected:
        rep.warn(name, f"no entry in DEFAULT_SCORE_BY_REGION for {code!r}; "
                       f"the ML side will fall back to IDRS.")

    status = model.get("validation_status")
    prior = (model.get("prevalence_prior") or {})

    if status == "validated":
        if not prior.get("source_verified"):
            rep.error(name, "validation_status is 'validated' but prevalence_prior is "
                            "not source_verified. A validated market cannot rest on an unverified prior.")
        if not model.get("calibration_model_version"):
            rep.error(name, "validation_status is 'validated' but no calibration_model_version is set.")
        if not model.get("validation_sets"):
            rep.error(name, "validation_status is 'validated' with no validation_sets listed.")
    else:
        if prior.get("value") is None:
            rep.warn(name, "prevalence_prior.value is null — market must run "
                           "clinical-score-only and show 'not validated' in the UI.")
        if not model.get("validation_sets"):
            rep.warn(name, "no validation_sets identified — this market has no path to "
                           "'validated' yet.")


def check_localisation(pack: dict, name: str, rep: Report) -> None:
    langs = pack.get("languages", [])
    default = pack.get("default_language")
    if default and default not in langs:
        rep.error(name, f"default_language {default!r} is not in languages {langs}")

    if pack.get("text_direction") == "rtl" and not any(
        l.startswith(("ar", "ur", "he", "fa")) for l in langs
    ):
        rep.warn(name, "text_direction is 'rtl' but no RTL language is listed")

    keys = [s.get("key") for s in pack.get("meal_slots", [])]
    if len(keys) != len(set(keys)):
        rep.error(name, "duplicate meal_slot keys")

    food = pack.get("food", {})
    if food.get("composition_licence_status") in ("permission_pending", "not_started"):
        rep.warn(name, f"food composition licence is "
                       f"{food.get('composition_licence_status')!r} — food logging is blocked here")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--strict", action="store_true", help="treat warnings as errors")
    args = parser.parse_args()

    if not SCHEMA.exists():
        print(f"Missing schema: {SCHEMA}")
        return 1
    schema = json.loads(SCHEMA.read_text(encoding="utf-8"))

    packs = sorted(p for p in PACKS.glob("*.json") if not p.name.startswith("_"))
    if not packs:
        print("No region packs found.")
        return 1

    rep = Report()
    print(f"Validating {len(packs)} region pack(s) against {SCHEMA.name}\n")

    for path in packs:
        name = path.stem
        try:
            pack = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            rep.error(name, f"invalid JSON: {exc}")
            continue

        if pack.get("code") != name:
            rep.error(name, f"code {pack.get('code')!r} does not match filename {name!r}")

        check_schema(pack, name, schema, rep)
        check_safety_floors(pack, name, rep)
        check_regulatory(pack, name, rep)
        check_model_readiness(pack, name, rep)
        check_localisation(pack, name, rep)

        status = (pack.get("risk_model") or {}).get("validation_status", "?")
        wave = pack.get("wave", "?")
        print(f"  {name}  wave {wave}  {pack.get('country','?'):24s} "
              f"{(pack.get('risk_model') or {}).get('clinical_score','?'):9s} {status}")

    print()
    for w in rep.warnings:
        print(f"  WARN   {w}")
    for e in rep.errors:
        print(f"  ERROR  {e}")

    print(f"\n{len(packs)} pack(s) · {len(rep.errors)} error(s) · {len(rep.warnings)} warning(s)")
    if rep.errors:
        return 1
    if rep.warnings and args.strict:
        print("--strict: warnings treated as errors")
        return 1
    print("All packs valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
