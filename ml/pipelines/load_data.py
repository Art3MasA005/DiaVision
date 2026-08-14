"""Load BRFSS, DiaBD and NHANES and harmonise them to one feature vocabulary.

Every dataset names the same concept differently, codes "don't know" as 7 or 9
or 77, and stores BMI multiplied by 100. This module is where all of that is
reconciled, exactly once, into the column names in
ml/contracts/feature_spec.json.

What the audit found (see docs/data_audit.md), because it shapes every choice here:

  * Neither BRFSS nor DiaBD has WAIST CIRCUMFERENCE. Only NHANES does. Waist is
    the single most valuable South Asian feature (Playbook §B9), so NHANES is
    the primary training source rather than the afterthought it was planned as.
  * BRFSS has no family-history variable at all. DiaBD has one, but at 3.2%
    prevalence and AUC 0.492 it carries no signal and is almost certainly a
    coding fault.
  * Missing stays missing. LightGBM handles NaN natively, and imputing a waist
    we never measured would fabricate the very feature we care most about.
"""

from __future__ import annotations

import glob
from pathlib import Path

import numpy as np
import pandas as pd

REPO_ROOT = Path(__file__).resolve().parents[2]
RAW = REPO_ROOT / "data" / "raw"
INTERIM = REPO_ROOT / "data" / "interim"

LABEL = "has_diabetes_or_prediabetes"

# The harmonised vocabulary. Any dataset lacking a column supplies NaN.
CANONICAL = [
    "age_years", "sex_at_birth", "height_cm", "weight_kg", "waist_cm",
    "family_history", "physical_activity", "smoker",
    "known_high_bp", "on_bp_meds", "history_high_glucose",
    "systolic_bp", "diastolic_bp", "fasting_glucose_mmol_l", "hba1c_percent",
]


def _finalise(df: pd.DataFrame, source: str) -> pd.DataFrame:
    """Add derived features, enforce the column set, drop impossible rows."""
    for col in CANONICAL:
        if col not in df.columns:
            df[col] = np.nan

    df["bmi"] = df["weight_kg"] / (df["height_cm"] / 100.0) ** 2
    df["waist_to_height_ratio"] = df["waist_cm"] / df["height_cm"]

    # Physiologically impossible values, from the audit. Blank the cell rather
    # than drop the row — one bad height should not discard a usable record.
    bounds = {
        "age_years": (18, 110), "height_cm": (120, 220), "weight_kg": (25, 250),
        "bmi": (12, 60), "waist_cm": (45, 200), "waist_to_height_ratio": (0.25, 1.2),
        "systolic_bp": (70, 250), "diastolic_bp": (40, 150),
        "fasting_glucose_mmol_l": (2.0, 35.0), "hba1c_percent": (3.0, 20.0),
    }
    for col, (lo, hi) in bounds.items():
        bad = (df[col] < lo) | (df[col] > hi)
        if bad.any():
            df.loc[bad, col] = np.nan

    df["source"] = source
    df = df.dropna(subset=["age_years", LABEL])
    df = df[df["age_years"] >= 18]  # PRD §3.3
    return df[CANONICAL + ["bmi", "waist_to_height_ratio", LABEL, "source"]].reset_index(drop=True)


# ──────────────────────────────────────────────────────────────────────
# BRFSS 2015
# ──────────────────────────────────────────────────────────────────────

# _AGEG5YR is banded; decode to band midpoints. 14 = don't know/refused.
_BRFSS_AGE_MIDPOINT = {
    1: 22, 2: 27, 3: 32, 4: 37, 5: 42, 6: 47, 7: 52,
    8: 57, 9: 62, 10: 67, 11: 72, 12: 77, 13: 82,
}

_BRFSS_COLS = [
    "_AGEG5YR", "SEX", "HTM4", "WTKG3", "_BMI5", "_TOTINDA", "SMOKE100",
    "_RFHYPE5", "BPMEDS", "PREDIAB1", "DIABETE3",
]


def load_brfss(path: Path | None = None, chunksize: int = 100_000) -> pd.DataFrame:
    """BRFSS 2015 — 441k US adults. Breadth, not depth: no waist, no family history."""
    path = path or (RAW / "brfss" / "LLCP2015.XPT")
    if not path.exists():
        raise FileNotFoundError(f"{path} — see docs/data_acquisition.md")

    frames = []
    for chunk in pd.read_sas(path, format="xport", chunksize=chunksize, iterator=True):
        frames.append(chunk[[c for c in _BRFSS_COLS if c in chunk.columns]].copy())
    raw = pd.concat(frames, ignore_index=True)

    df = pd.DataFrame(index=raw.index)
    df["age_years"] = raw["_AGEG5YR"].map(_BRFSS_AGE_MIDPOINT)
    df["sex_at_birth"] = raw["SEX"].map({1: "male", 2: "female"})
    df["height_cm"] = raw["HTM4"]
    df["weight_kg"] = raw["WTKG3"] / 100.0       # stored as kg * 100
    # _BMI5 is BMI * 100, but we recompute from height/weight in _finalise so
    # BMI stays consistent with the anthropometry rather than diverging from it.

    # _TOTINDA: 1 = any leisure-time activity, 2 = none. A two-level source
    # feeding a five-level runtime scale — collapse at training time, never at
    # runtime, and record the mismatch in the model card.
    df["physical_activity"] = raw["_TOTINDA"].map({1: "moderate", 2: "sedentary"})
    df["smoker"] = raw["SMOKE100"].map({1: True, 2: False})
    df["known_high_bp"] = raw["_RFHYPE5"].map({1: False, 2: True})
    df["on_bp_meds"] = raw["BPMEDS"].map({1: True, 2: False})
    df["history_high_glucose"] = raw["PREDIAB1"].map({1: True, 2: True, 3: False})

    # DIABETE3: 1=yes 2=yes-during-pregnancy 3=no 4=prediabetes 7=DK 9=refused.
    # Gestational and DK/refused are excluded rather than guessed; PRD §2.2 puts
    # gestational diabetes out of scope entirely.
    diab = raw["DIABETE3"]
    df[LABEL] = np.where(diab == 1, 1.0, np.where(diab.isin([3, 4]), 0.0, np.nan))

    return _finalise(df, "brfss")


# ──────────────────────────────────────────────────────────────────────
# DiaBD
# ──────────────────────────────────────────────────────────────────────

def load_diabd(path: Path | None = None) -> pd.DataFrame:
    """DiaBD — 5,288 Bangladeshi patients. The external validation set.

    Held out of training entirely. Playbook §B3: holding out one whole dataset
    is the only number that predicts real-world performance.
    """
    if path is None:
        matches = glob.glob(str(RAW / "diabd" / "*.csv"))
        if not matches:
            raise FileNotFoundError("No DiaBD csv — see docs/data_acquisition.md")
        path = Path(matches[0])

    raw = pd.read_csv(path)
    df = pd.DataFrame(index=raw.index)
    df["age_years"] = raw["age"]
    df["sex_at_birth"] = raw["gender"].str.lower().map({"male": "male", "female": "female"})
    df["height_cm"] = raw["height"] * 100.0      # stored in metres
    df["weight_kg"] = raw["weight"]
    df["systolic_bp"] = raw["systolic_bp"]
    df["diastolic_bp"] = raw["diastolic_bp"]
    df["fasting_glucose_mmol_l"] = raw["glucose"]
    df["known_high_bp"] = raw["hypertensive"].astype(bool)

    # 3.2% prevalence, univariate AUC 0.492 — no signal. Mapped for completeness
    # and then excluded by the caller; see docs/data_audit.md.
    df["family_history"] = np.where(raw["family_diabetes"] == 1, "first_degree", "none")

    df[LABEL] = (raw["diabetic"].str.strip().str.lower() == "yes").astype(float)
    return _finalise(df, "diabd")


# ──────────────────────────────────────────────────────────────────────
# NHANES 2017-2018
# ──────────────────────────────────────────────────────────────────────

_NHANES_DIR = RAW / "nhanes" / "2017-2018"


def _nh(name: str, cols: list[str]) -> pd.DataFrame:
    df = pd.read_sas(_NHANES_DIR / f"{name}.xpt", format="xport")
    return df[[c for c in cols if c in df.columns]]


def load_nhanes(label_definition: str = "diabetes") -> pd.DataFrame:
    """NHANES 2017-2018 — the only source with waist AND objective labels.

    `label_definition`:
      "diabetes"    HbA1c >= 6.5 or FPG >= 7.0 or self-reported diagnosis.
                    ~20% positive. The shipped target.
      "prediabetes" adds HbA1c >= 5.7 / FPG >= 5.6. ~55% positive — flags over
                    half of all adults, which makes "go get tested" meaningless.
    """
    demo = _nh("DEMO_J", ["SEQN", "RIAGENDR", "RIDAGEYR"])
    bmx = _nh("BMX_J", ["SEQN", "BMXWT", "BMXHT", "BMXWAIST"])
    bpx = _nh("BPX_J", ["SEQN", "BPXSY1", "BPXDI1"])
    ghb = _nh("GHB_J", ["SEQN", "LBXGH"])
    glu = _nh("GLU_J", ["SEQN", "LBDGLUSI"])
    diq = _nh("DIQ_J", ["SEQN", "DIQ010", "DIQ160"])
    bpq = _nh("BPQ_J", ["SEQN", "BPQ020", "BPQ040A", "BPQ050A"])
    smq = _nh("SMQ_J", ["SEQN", "SMQ020"])
    paq = _nh("PAQ_J", ["SEQN", "PAQ605", "PAQ620", "PAQ650", "PAQ665"])
    mcq = _nh("MCQ_J", ["SEQN", "MCQ300C"])

    raw = demo
    for part in (bmx, bpx, ghb, glu, diq, bpq, smq, paq, mcq):
        raw = raw.merge(part, on="SEQN", how="left")

    df = pd.DataFrame(index=raw.index)
    df["age_years"] = raw["RIDAGEYR"]
    df["sex_at_birth"] = raw["RIAGENDR"].map({1: "male", 2: "female"})
    df["height_cm"] = raw["BMXHT"]
    df["weight_kg"] = raw["BMXWT"]
    df["waist_cm"] = raw["BMXWAIST"]
    df["systolic_bp"] = raw["BPXSY1"]
    df["diastolic_bp"] = raw["BPXDI1"]
    df["hba1c_percent"] = raw["LBXGH"]
    df["fasting_glucose_mmol_l"] = raw["LBDGLUSI"]

    # MCQ300C — close relative with diabetes. 1=yes 2=no, 7/9 = DK/refused.
    df["family_history"] = raw["MCQ300C"].map({1: "first_degree", 2: "none"})

    # Vigorous work/recreation -> active; moderate -> moderate; neither ->
    # sedentary. Only assigned where at least one question was answered.
    vigorous = raw["PAQ605"].eq(1) | raw["PAQ650"].eq(1)
    moderate = raw["PAQ620"].eq(1) | raw["PAQ665"].eq(1)
    answered = raw[["PAQ605", "PAQ620", "PAQ650", "PAQ665"]].isin([1, 2]).any(axis=1)
    df["physical_activity"] = np.select(
        [~answered, vigorous, moderate], [None, "active", "moderate"], default="sedentary")
    df.loc[~answered, "physical_activity"] = np.nan

    df["smoker"] = raw["SMQ020"].map({1: True, 2: False})
    df["known_high_bp"] = raw["BPQ020"].map({1: True, 2: False})
    df["on_bp_meds"] = raw["BPQ050A"].map({1: True, 2: False})
    df["history_high_glucose"] = raw["DIQ160"].map({1: True, 2: False})

    a1c, fpg = raw["LBXGH"], raw["LBDGLUSI"]
    diagnosed = raw["DIQ010"].eq(1)
    if label_definition == "prediabetes":
        positive = (a1c >= 5.7) | (fpg >= 5.6) | diagnosed
    else:
        positive = (a1c >= 6.5) | (fpg >= 7.0) | diagnosed

    # Only rows with SOME basis for a label. An unmeasured person is not a negative.
    has_basis = a1c.notna() | fpg.notna() | raw["DIQ010"].isin([1, 2])
    df[LABEL] = np.where(has_basis, positive.astype(float), np.nan)

    return _finalise(df, "nhanes")


# ──────────────────────────────────────────────────────────────────────

def load_all(cache: bool = True) -> dict[str, pd.DataFrame]:
    """Load every available dataset, caching the slow BRFSS parse to parquet."""
    out: dict[str, pd.DataFrame] = {}

    brfss_cache = INTERIM / "brfss_2015.parquet"
    if cache and brfss_cache.exists():
        out["brfss"] = pd.read_parquet(brfss_cache)
    else:
        try:
            out["brfss"] = load_brfss()
            if cache:
                INTERIM.mkdir(parents=True, exist_ok=True)
                out["brfss"].to_parquet(brfss_cache, index=False)
        except FileNotFoundError as exc:
            print(f"  skipping BRFSS: {exc}")

    for name, fn in (("nhanes", load_nhanes), ("diabd", load_diabd)):
        try:
            out[name] = fn()
        except FileNotFoundError as exc:
            print(f"  skipping {name}: {exc}")
    return out


if __name__ == "__main__":
    for name, df in load_all().items():
        cover = {c: f"{df[c].notna().mean():.0%}" for c in
                 ("waist_cm", "family_history", "physical_activity", "smoker")}
        print(f"\n{name:8s} {len(df):>7,} rows   positive {df[LABEL].mean():.2%}")
        print(f"         coverage: {cover}")
