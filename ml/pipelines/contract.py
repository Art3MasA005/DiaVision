"""Load ml/contracts/feature_spec.json and turn it into a usable feature list.

The contract is the single source of truth for which attributes we ask the user
for, which of those reach the model, and what a valid value looks like. The
training pipeline, the inference path, the API schema and the Flutter wizard
all derive from this file rather than each maintaining their own copy — that
duplication is exactly how a model ends up trained on features the app never
collects.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
SPEC_PATH = REPO_ROOT / "ml" / "contracts" / "feature_spec.json"


@dataclass(frozen=True)
class Feature:
    name: str
    type: str
    tier: int
    required: bool
    status: str
    modifiable: bool
    values: tuple[str, ...] | None = None
    range: tuple[float, float] | None = None
    unit: str | None = None
    notes: str = ""
    ui_key: str = ""

    @property
    def is_categorical(self) -> bool:
        return self.type in ("categorical", "ordinal")

    @property
    def trains(self) -> bool:
        """Whether this feature is allowed into the model right now.

        `audit_pending` features are held out until the leakage audit rules on
        them. Defaulting to EXCLUDED is deliberate: an unaudited feature that
        silently trains is how a leaky model ships.
        """
        return self.status == "allowed"


@dataclass(frozen=True)
class Derived:
    name: str
    formula: str
    range: tuple[float, float] | None
    notes: str = ""


class Contract:
    def __init__(self, raw: dict[str, Any]) -> None:
        self.raw = raw
        self.version: str = raw["version"]
        self.status: str = raw["status"]
        self.features = [
            Feature(
                name=f["name"], type=f["type"], tier=f["tier"],
                required=f.get("required", False), status=f["status"],
                modifiable=f.get("modifiable", True),
                values=tuple(f["values"]) if f.get("values") else None,
                range=tuple(f["range"]) if f.get("range") else None,
                unit=f.get("unit"), notes=f.get("notes", ""), ui_key=f.get("ui_key", ""),
            )
            for f in raw["features"]
        ]
        self.derived = [
            Derived(name=d["name"], formula=d["formula"],
                    range=tuple(d["range"]) if d.get("range") else None,
                    notes=d.get("notes", ""))
            for d in raw.get("derived", [])
        ]
        self.excluded_for_leakage: dict[str, str] = {
            k: v for k, v in raw.get("excluded_for_leakage", {}).items()
            if not k.startswith("$")
        }
        self.label = raw["label"]
        self.bounds = raw["sanity_bounds"]

    # ── selection ─────────────────────────────────────────────────────

    def asked_of_user(self, tier: int = 1) -> list[Feature]:
        """Everything the onboarding wizard collects for this tier."""
        return [f for f in self.features if f.tier <= tier]

    def model_inputs(self, tier: int = 1, include_pending: bool = False) -> list[str]:
        """Column names the model actually trains on, derived features included."""
        cols = [
            f.name for f in self.features
            if f.tier <= tier and (f.trains or (include_pending and f.status == "audit_pending"))
        ]
        return cols + [d.name for d in self.derived]

    def audit_pending(self) -> list[Feature]:
        return [f for f in self.features if f.status == "audit_pending"]

    def by_name(self, name: str) -> Feature | None:
        return next((f for f in self.features if f.name == name), None)

    # ── validation ────────────────────────────────────────────────────

    def validate(self, record: dict[str, Any], tier: int = 1) -> list[str]:
        """Check one user-supplied record. Returns a list of problems."""
        problems: list[str] = []
        for f in self.asked_of_user(tier):
            value = record.get(f.name)
            if value is None:
                if f.required and f.tier <= tier:
                    problems.append(f"{f.name} is required")
                continue
            if f.values and value not in f.values:
                problems.append(f"{f.name}={value!r} not in {list(f.values)}")
            if f.range and isinstance(value, (int, float)):
                lo, hi = f.range
                if not lo <= value <= hi:
                    problems.append(f"{f.name}={value} outside [{lo}, {hi}]")
        return problems


@lru_cache(maxsize=1)
def load_contract(path: Path | None = None) -> Contract:
    return Contract(json.loads((path or SPEC_PATH).read_text(encoding="utf-8")))


def add_derived(record: dict[str, Any]) -> dict[str, Any]:
    """Compute BMI and waist-to-height. Returns a new dict; never mutates.

    Kept as explicit code rather than eval() of the formula string in the
    contract: the contract documents the formula for humans, this computes it
    for machines, and the test suite asserts they agree.
    """
    out = dict(record)
    height = record.get("height_cm")
    weight = record.get("weight_kg")
    waist = record.get("waist_cm")

    out["bmi"] = weight / (height / 100.0) ** 2 if height and weight else None
    out["waist_to_height_ratio"] = waist / height if height and waist else None
    return out
