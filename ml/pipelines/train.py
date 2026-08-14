"""Model A training pipeline — the hybrid risk model.

Implements Playbook §B8 end to end:

    1. SPLIT FIRST, before any imputation, scaling, resampling or selection
    2. Train LightGBM with class weights (NOT SMOTE) on the train fold
    3. Fit isotonic calibration on a held-out CALIBRATION fold
    4. Compute a published clinical score (IDRS / FINDRISC / ADA)
    5. Blend:  final = w * calibrated_GBM + (1-w) * calibrated_clinical
       with w tuned on a separate VALIDATION fold
    6. Evaluate once on TEST, which nothing else has touched

Four folds, not three, because tuning the blend weight on the same data used
to fit the calibrators would leak. Playbook §B3: "if you look at it and then
tune, it's a validation set now."

A regularised logistic regression is trained alongside as the sanity baseline.
Playbook §B6 is explicit that if the GBM beats it by only ~0.01 AUC we should
ship the logistic model instead — explainable, tiny, trivially defensible.

Usage:
    python ml/pipelines/train.py --synthetic     # pipeline check, no real data
    python ml/pipelines/train.py                 # real data (needs BRFSS + DiaBD)
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import lightgbm as lgb  # noqa: E402
from sklearn.isotonic import IsotonicRegression  # noqa: E402
from sklearn.linear_model import LogisticRegression  # noqa: E402
from sklearn.model_selection import train_test_split  # noqa: E402
from sklearn.pipeline import Pipeline  # noqa: E402
from sklearn.preprocessing import OneHotEncoder, StandardScaler  # noqa: E402
from sklearn.compose import ColumnTransformer  # noqa: E402
from sklearn.impute import SimpleImputer  # noqa: E402

from pipelines import evaluate as ev  # noqa: E402
from pipelines.clinical_scores import Subject, score_for_region  # noqa: E402
from pipelines.contract import load_contract  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = REPO_ROOT / "ml" / "artifacts"
REPORTS = REPO_ROOT / "ml" / "reports"

LABEL = "has_diabetes_or_prediabetes"
SEED = 42


# ──────────────────────────────────────────────────────────────────────
# Splitting — this happens FIRST, always
# ──────────────────────────────────────────────────────────────────────

@dataclass
class Folds:
    train: pd.DataFrame
    cal: pd.DataFrame
    val: pd.DataFrame
    test: pd.DataFrame

    def summary(self) -> str:
        return "  ".join(
            f"{name}={len(df):,} ({df[LABEL].mean():.1%}+)"
            for name, df in (("train", self.train), ("cal", self.cal),
                             ("val", self.val), ("test", self.test))
        )


def split(df: pd.DataFrame, seed: int = SEED) -> Folds:
    """60 / 20 / 10 / 10, stratified. Nothing is fitted before this runs."""
    train, rest = train_test_split(df, test_size=0.40, stratify=df[LABEL], random_state=seed)
    cal, rest2 = train_test_split(rest, test_size=0.50, stratify=rest[LABEL], random_state=seed)
    val, test = train_test_split(rest2, test_size=0.50, stratify=rest2[LABEL], random_state=seed)
    return Folds(train.copy(), cal.copy(), val.copy(), test.copy())


# ──────────────────────────────────────────────────────────────────────
# Layer 2 — the gradient booster
# ──────────────────────────────────────────────────────────────────────

def build_preprocessor(numeric: list[str], categorical: list[str]) -> ColumnTransformer:
    """Everything inside a Pipeline so cross-validation cannot leak (Playbook §B3).

    Note the numeric imputer: median for genuinely-missing anthropometry only.
    Lab values are NEVER imputed — Playbook §B7 — they route to Tier 1 instead,
    which is enforced by keeping them out of the Tier-1 feature list entirely.
    """
    return ColumnTransformer([
        ("num", Pipeline([
            ("impute", SimpleImputer(strategy="median", add_indicator=True)),
            ("scale", StandardScaler()),
        ]), numeric),
        ("cat", Pipeline([
            ("impute", SimpleImputer(strategy="most_frequent")),
            ("encode", OneHotEncoder(handle_unknown="ignore", sparse_output=False)),
        ]), categorical),
    ], remainder="drop")


def train_gbm(folds: Folds, numeric: list[str], categorical: list[str]) -> lgb.LGBMClassifier:
    """LightGBM with class weights. No SMOTE — Playbook §B4.

    scale_pos_weight preserves calibration, which matters more than accuracy
    for this product. SMOTE frequently damages it, and the damage is invisible
    in an accuracy number.
    """
    # LightGBM handles NaN natively — important because waist is absent from
    # the BRFSS pretraining corpus entirely and must not be imputed away.
    #
    # reset_index and to_numpy are load-bearing, not tidiness: train_test_split
    # leaves a shuffled index, and passing the resulting non-contiguous label
    # Series straight to LightGBM 4.7 on Windows crashes the native library
    # with an access violation rather than raising.
    X = folds.train[numeric + categorical].copy().reset_index(drop=True)
    for col in categorical:
        X[col] = X[col].astype("category")
    y = np.ascontiguousarray(folds.train[LABEL].to_numpy(dtype=np.float64))

    n_neg, n_pos = int((y == 0).sum()), int((y == 1).sum())
    model = lgb.LGBMClassifier(
        objective="binary",
        n_estimators=400,
        learning_rate=0.05,
        num_leaves=31,
        min_child_samples=40,
        subsample=0.85,
        subsample_freq=1,
        colsample_bytree=0.85,
        reg_lambda=1.0,
        scale_pos_weight=n_neg / max(n_pos, 1),
        random_state=SEED,
        n_jobs=-1,
        verbose=-1,
    )
    model.fit(X, y, categorical_feature=categorical)
    return model


def gbm_predict(model: lgb.LGBMClassifier, df: pd.DataFrame,
                numeric: list[str], categorical: list[str]) -> np.ndarray:
    X = df[numeric + categorical].copy().reset_index(drop=True)
    for col in categorical:
        X[col] = X[col].astype("category")
    return model.predict_proba(X)[:, 1]


def train_baseline(folds: Folds, numeric: list[str], categorical: list[str]) -> Pipeline:
    """Regularised logistic regression — the sanity check and the fallback."""
    pipe = Pipeline([
        ("prep", build_preprocessor(numeric, categorical)),
        ("clf", LogisticRegression(max_iter=2000, class_weight="balanced", C=1.0,
                                   random_state=SEED)),
    ])
    pipe.fit(folds.train[numeric + categorical], folds.train[LABEL])
    return pipe


# ──────────────────────────────────────────────────────────────────────
# Layer 1 — the clinical score, as a probability
# ──────────────────────────────────────────────────────────────────────

def clinical_points(df: pd.DataFrame, region: str) -> np.ndarray:
    """Run the published score over a frame, returning normalised points."""
    out = np.empty(len(df), dtype=float)
    for i, (_, row) in enumerate(df.iterrows()):
        waist = row.get("waist_cm")
        subject = Subject(
            age_years=int(row["age_years"]),
            sex_at_birth=row["sex_at_birth"],
            height_cm=float(row["height_cm"]),
            weight_kg=float(row["weight_kg"]),
            waist_cm=None if waist is None or pd.isna(waist) else float(waist),
            family_history=row.get("family_history", "none"),
            physical_activity=row.get("physical_activity", "sedentary"),
            smoker=bool(row.get("smoker", False)),
            known_high_bp=bool(row.get("known_high_bp", False)),
            on_bp_meds=bool(row.get("on_bp_meds", False)),
            history_high_glucose=bool(row.get("history_high_glucose", False)),
        )
        out[i] = score_for_region(subject, region).fraction
    return out


# ──────────────────────────────────────────────────────────────────────
# Blending
# ──────────────────────────────────────────────────────────────────────

def tune_blend_weight(y: np.ndarray, p_gbm: np.ndarray, p_clin: np.ndarray
                      ) -> tuple[float, float]:
    """Pick w on the VALIDATION fold by Brier score, not AUC.

    Brier because calibration is what this product sells. Choosing w by AUC
    would optimise ranking and quietly accept a worse-calibrated number.
    """
    best_w, best_brier = 0.65, float("inf")
    for w in np.linspace(0.0, 1.0, 21):
        blended = w * p_gbm + (1 - w) * p_clin
        brier = float(np.mean((blended - y) ** 2))
        if brier < best_brier:
            best_w, best_brier = float(w), brier
    return best_w, best_brier


# ──────────────────────────────────────────────────────────────────────
# Orchestration
# ──────────────────────────────────────────────────────────────────────

def run(df: pd.DataFrame, region: str, is_synthetic: bool, out_tag: str) -> dict:
    contract = load_contract()
    numeric = [f.name for f in contract.features
               if f.trains and f.tier == 1 and f.type in ("integer", "float")]
    numeric += [d.name for d in contract.derived]
    categorical = [f.name for f in contract.features
                   if f.trains and f.tier == 1 and (f.is_categorical or f.type == "boolean")]

    numeric = [c for c in numeric if c in df.columns]
    categorical = [c for c in categorical if c in df.columns]

    print(f"\nContract v{contract.version} ({contract.status})")
    print(f"  numeric     : {numeric}")
    print(f"  categorical : {categorical}")
    held = [f.name for f in contract.audit_pending()]
    print(f"  held back pending leakage audit: {held}")

    folds = split(df)
    print(f"\nSplit (before anything else)\n  {folds.summary()}")

    print("\nTraining LightGBM (class weights, no SMOTE) ...")
    gbm = train_gbm(folds, numeric, categorical)
    baseline = train_baseline(folds, numeric, categorical)

    # ── raw predictions per fold ──────────────────────────────────────
    raw = {name: gbm_predict(gbm, getattr(folds, name), numeric, categorical)
           for name in ("cal", "val", "test")}
    clin = {name: clinical_points(getattr(folds, name), region)
            for name in ("cal", "val", "test")}

    # ── isotonic calibration, fitted ONLY on the cal fold ─────────────
    print("Fitting isotonic calibration on the held-out calibration fold ...")
    iso_gbm = IsotonicRegression(out_of_bounds="clip").fit(raw["cal"], folds.cal[LABEL])
    iso_clin = IsotonicRegression(out_of_bounds="clip").fit(clin["cal"], folds.cal[LABEL])

    cal_gbm = {k: iso_gbm.predict(v) for k, v in raw.items()}
    cal_clin = {k: iso_clin.predict(v) for k, v in clin.items()}

    # ── blend weight tuned on the val fold ────────────────────────────
    w, val_brier = tune_blend_weight(
        folds.val[LABEL].to_numpy(), cal_gbm["val"], cal_clin["val"])
    print(f"Blend weight w = {w:.2f} (GBM share), tuned on validation by Brier = {val_brier:.4f}")

    blended_test = w * cal_gbm["test"] + (1 - w) * cal_clin["test"]

    # ── evaluate, once, on test ───────────────────────────────────────
    y_test = folds.test[LABEL].to_numpy()
    groups = {
        "sex": folds.test["sex_at_birth"].to_numpy(),
        "age_band": pd.cut(folds.test["age_years"],
                           [17, 29, 39, 49, 59, 120],
                           labels=["18-29", "30-39", "40-49", "50-59", "60+"]).astype(str).to_numpy(),
    }
    bounds = contract.bounds

    results = {}
    for name, preds in (
        ("clinical_score_only", cal_clin["test"]),
        ("gbm_uncalibrated", raw["test"]),
        ("gbm_calibrated", cal_gbm["test"]),
        ("blended", blended_test),
    ):
        results[name] = ev.evaluate(
            y_test, preds, groups=groups if name == "blended" else None,
            target_sensitivity=bounds["target_sensitivity"],
            min_specificity=bounds["min_specificity_at_target_sensitivity"],
            leakage_alarm_auc=bounds["leakage_alarm_auc"],
        )

    base_pred = baseline.predict_proba(folds.test[numeric + categorical])[:, 1]
    results["logistic_baseline"] = ev.evaluate(y_test, base_pred)

    # ── report ────────────────────────────────────────────────────────
    print()
    for name in ("clinical_score_only", "logistic_baseline", "gbm_uncalibrated",
                 "gbm_calibrated", "blended"):
        print(ev.format_report(results[name], f"\n{name}"))
        print()

    gap = results["blended"].auc_roc - results["logistic_baseline"].auc_roc
    print(f"\nGBM blend beats the logistic baseline by {gap:+.4f} AUC.")
    if gap < 0.01:
        print("  Playbook §B6: that is inside noise. Ship the logistic model —")
        print("  explainable, tiny, and trivially defensible to a regulator.")

    cal_gain = results["gbm_uncalibrated"].ece - results["gbm_calibrated"].ece
    print(f"Isotonic calibration reduced ECE by {cal_gain:.4f} "
          f"({results['gbm_uncalibrated'].ece:.4f} -> {results['gbm_calibrated'].ece:.4f}).")

    # ── persist ───────────────────────────────────────────────────────
    REPORTS.mkdir(parents=True, exist_ok=True)
    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "synthetic": is_synthetic,
        "warning": (ev and None) or None,
        "contract_version": contract.version,
        "contract_status": contract.status,
        "region": region,
        "blend_weight_gbm": w,
        "features": {"numeric": numeric, "categorical": categorical,
                     "held_back_pending_audit": held},
        "fold_sizes": {k: int(len(getattr(folds, k))) for k in ("train", "cal", "val", "test")},
        "metrics": {k: v.to_dict() for k, v in results.items()},
    }
    if is_synthetic:
        payload["WARNING"] = (
            "SYNTHETIC DATA. These numbers verify the pipeline works. They are NOT "
            "accuracy claims and must never appear in a model card or in the app."
        )
    path = REPORTS / f"metrics_{out_tag}.json"
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"\nWrote {path.relative_to(REPO_ROOT)}")

    # ── save the servable bundle ──────────────────────────────────────
    import joblib

    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    bundle = {
        "schema": 1,
        "trained_at": payload["generated_at"],
        "synthetic": is_synthetic,
        "contract_version": contract.version,
        "region": region,
        "gbm": gbm,
        "isotonic_gbm": iso_gbm,
        "isotonic_clinical": iso_clin,
        "blend_weight_gbm": w,
        "numeric": numeric,
        "categorical": categorical,
        "operating_threshold": results["blended"].threshold_at_target,
        "test_metrics": {
            "auc_roc": results["blended"].auc_roc,
            "auc_pr": results["blended"].auc_pr,
            "brier": results["blended"].brier,
            "ece": results["blended"].ece,
        },
    }
    model_path = ARTIFACTS / f"model_a_{out_tag}.joblib"
    joblib.dump(bundle, model_path)
    print(f"Wrote {model_path.relative_to(REPO_ROOT)}")
    if is_synthetic:
        print("  (synthetic bundle — for wiring up the API only, never for a real user)")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--synthetic", action="store_true",
                        help="run on generated data to verify the pipeline")
    parser.add_argument("--n", type=int, default=40_000, help="synthetic cohort size")
    parser.add_argument("--region", default="bd")
    args = parser.parse_args()

    if args.synthetic:
        from pipelines.synthetic import SYNTHETIC_WARNING, bayes_optimal_auc, generate
        print("=" * 72)
        print(SYNTHETIC_WARNING)
        print("=" * 72)
        df = generate(n=args.n, seed=SEED)
        ceiling = bayes_optimal_auc(df)
        print(f"\nGenerated {len(df):,} rows · positive rate {df[LABEL].mean():.1%}")
        print(f"Bayes-optimal AUC (the ceiling a perfect model could reach): {ceiling:.4f}")
        print("A pipeline scoring meaningfully above this is leaking.")
        run(df.drop(columns=["true_probability"]), args.region, True, "synthetic")
        return 0

    manifest = REPO_ROOT / "data" / "raw" / "MANIFEST.json"
    have = json.loads(manifest.read_text(encoding="utf-8"))["datasets"] if manifest.exists() else {}
    missing = [k for k in ("brfss", "diabd") if not have.get(k, {}).get("files")]
    if missing:
        print(f"Missing required datasets: {', '.join(missing)}")
        print("See docs/data_acquisition.md — both need a browser download.")
        print("\nTo verify the pipeline meanwhile:")
        print("    python ml/pipelines/train.py --synthetic")
        return 1

    print("Real-data path not yet implemented — BRFSS/DiaBD loaders land once the files do.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
