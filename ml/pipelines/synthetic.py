"""Synthetic cohort generator — FOR PIPELINE TESTING ONLY.

⚠️  NOTHING PRODUCED HERE IS REAL DATA.
⚠️  NO METRIC COMPUTED ON IT IS AN ACCURACY CLAIM.
⚠️  IT MUST NEVER APPEAR IN A MODEL CARD OR ANY USER-FACING NUMBER.

Why it exists: the training pipeline (split → fit → calibrate → blend →
evaluate) is a lot of machinery, and every published-paper failure mode the
Playbook warns about is a *plumbing* bug — resampling before the split,
imputing a lab value, calibrating on the test set. Those bugs are far easier to
find against data whose true structure you already know.

So this generates a cohort from an explicit, documented risk function. That
gives two things real data cannot:

  1. A known ceiling. We generate the label by sampling from a true
     probability, so there is irreducible noise and a computable Bayes-optimal
     AUC. If the pipeline scores meaningfully ABOVE it, there is leakage — and
     leakage is exactly what we are trying to build defences against.
  2. Known calibration. The true probability of every row is knowable, so we
     can verify the isotonic step actually improves calibration rather than
     assuming it did.

When BRFSS and DiaBD arrive, `train.py` swaps its loader and nothing else in
the pipeline changes.

The marginal distributions below are shaped to be *plausible* for a South Asian
adult population — they are not fitted to any dataset.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

SYNTHETIC_WARNING = (
    "SYNTHETIC DATA — pipeline test only. Not real. Any metric computed on this "
    "is a plumbing check, never an accuracy claim."
)

# Ground-truth coefficients on a logit scale.
#
# Tuned so the Bayes-optimal AUC lands inside the 0.78-0.86 band the Playbook
# calls realistic for a questionnaire-only model. That matters: if the
# synthetic ceiling were 0.72, a pipeline bug that inflated scores to 0.80
# would look like success rather than an alarm. The ceiling has to sit where
# the real one will.
#
# No single feature dominates — a model that could nail this from one column
# would exercise none of the machinery we are trying to test.
TRUE_COEFFICIENTS = {
    "intercept": -4.60,
    "age_per_decade_over_30": 0.62,
    "waist_to_height_over_half": 9.50,   # the dominant real-world signal
    "bmi_over_23": 0.135,                # Asian-Pacific cutoff, per Playbook B9
    "family_first_degree": 1.25,
    "family_second_degree": 0.55,
    "sedentary": 0.70,
    "light_activity": 0.32,
    "male": 0.26,
    "smoker": 0.34,
}


def _activity(rng: np.random.Generator, n: int) -> np.ndarray:
    return rng.choice(
        ["sedentary", "light", "moderate", "active", "very_active"],
        size=n, p=[0.34, 0.27, 0.22, 0.12, 0.05],
    )


def _family_history(rng: np.random.Generator, n: int) -> np.ndarray:
    return rng.choice(
        ["none", "second_degree", "first_degree"], size=n, p=[0.55, 0.27, 0.18]
    )


def true_probability(df: pd.DataFrame) -> np.ndarray:
    """The generating risk function. Real data has no such thing — that is the point."""
    c = TRUE_COEFFICIENTS
    logit = np.full(len(df), c["intercept"], dtype=float)

    logit += c["age_per_decade_over_30"] * np.maximum(df["age_years"] - 30, 0) / 10.0
    logit += c["waist_to_height_over_half"] * np.maximum(df["waist_to_height_ratio"] - 0.5, 0)
    logit += c["bmi_over_23"] * np.maximum(df["bmi"] - 23.0, 0)
    logit += c["family_first_degree"] * (df["family_history"] == "first_degree")
    logit += c["family_second_degree"] * (df["family_history"] == "second_degree")
    logit += c["sedentary"] * (df["physical_activity"] == "sedentary")
    logit += c["light_activity"] * (df["physical_activity"] == "light")
    logit += c["male"] * (df["sex_at_birth"] == "male")
    logit += c["smoker"] * df["smoker"].astype(bool)

    return 1.0 / (1.0 + np.exp(-logit))


def generate(n: int = 40_000, seed: int = 42, waist_missing_rate: float = 0.0) -> pd.DataFrame:
    """Build a synthetic cohort.

    `waist_missing_rate` simulates the real BRFSS problem: the pretraining
    corpus has no waist column at all, so the model must cope with waist
    missing at pretrain and present at fine-tune. Set it to 1.0 to reproduce
    that exactly.
    """
    rng = np.random.default_rng(seed)

    sex = rng.choice(["male", "female"], size=n, p=[0.49, 0.51])
    male = sex == "male"

    # Age: skewed toward working age, floored at 18 per PRD §3.3.
    age = np.clip(rng.gamma(shape=7.0, scale=5.6, size=n) + 18, 18, 95).astype(int)

    height = np.where(male, rng.normal(168, 6.8, n), rng.normal(155, 6.2, n)).clip(140, 200)
    bmi_raw = rng.gamma(shape=42.0, scale=0.57, size=n).clip(14, 52)
    weight = bmi_raw * (height / 100.0) ** 2

    # Waist correlates with BMI but carries its own signal — which is exactly
    # why Playbook B9 wants it as a feature rather than trusting BMI alone.
    waist_base = np.where(male, 0.52, 0.50) * height
    waist = (waist_base + 1.9 * (bmi_raw - 23) + rng.normal(0, 4.5, n)).clip(50, 170)

    df = pd.DataFrame({
        "age_years": age,
        "sex_at_birth": sex,
        "height_cm": height.round(1),
        "weight_kg": weight.round(1),
        "waist_cm": waist.round(1),
        "family_history": _family_history(rng, n),
        "physical_activity": _activity(rng, n),
        "smoker": np.where(male, rng.random(n) < 0.34, rng.random(n) < 0.02),
    })

    df["bmi"] = df["weight_kg"] / (df["height_cm"] / 100.0) ** 2
    df["waist_to_height_ratio"] = df["waist_cm"] / df["height_cm"]

    # Sample the label from the true probability. This irreducible noise is
    # what makes a perfect score impossible — and therefore what makes an
    # impossibly high score a reliable leakage alarm.
    p = true_probability(df)
    df["true_probability"] = p
    df["has_diabetes_or_prediabetes"] = (rng.random(n) < p).astype(int)

    if waist_missing_rate > 0:
        drop = rng.random(n) < waist_missing_rate
        df.loc[drop, "waist_cm"] = np.nan
        df.loc[drop, "waist_to_height_ratio"] = np.nan

    return df


def bayes_optimal_auc(df: pd.DataFrame) -> float:
    """AUC achievable by a model that knows the true probability exactly.

    The ceiling. A pipeline scoring above this on synthetic data is leaking.
    """
    from sklearn.metrics import roc_auc_score
    return roc_auc_score(df["has_diabetes_or_prediabetes"], df["true_probability"])
