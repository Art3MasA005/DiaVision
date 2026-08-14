"""Leakage audit — the gate on freezing the feature contract.

Playbook §B2: three features in the contract are marked `audit_pending` because
each is plausibly a consequence of *being inside the healthcare system* rather
than of physiology:

    known_high_bp          often diagnosed at the same visit as the diabetes
    on_bp_meds             requires a prescription, therefore a doctor
    history_high_glucose   "were you ever told you have high blood sugar" is
                           close to the label itself, and is unanswerable for
                           someone who has never been tested

The test: train once with them, once without. If AUC collapses without them,
they were doing the work — and the model will fail on an undiagnosed person who
has never seen a doctor, which is exactly our target user.

The output is a decision per feature, written to docs/leakage_audit.md, plus a
"realistic" figure: how the with-features model scores on the subpopulation
that has never been screened. That gap is the real cost of keeping them.

Usage:
    python -m ml.pipelines.leakage_audit
"""

from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.metrics import average_precision_score, roc_auc_score
from sklearn.model_selection import train_test_split

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "ml"))

import lightgbm as lgb  # noqa: E402

from pipelines.load_data import LABEL, load_all  # noqa: E402

SEED = 42

SUSPECTS = ["known_high_bp", "on_bp_meds", "history_high_glucose"]

CLEAN = ["age_years", "sex_at_birth", "height_cm", "weight_kg", "waist_cm",
         "bmi", "waist_to_height_ratio", "family_history", "physical_activity", "smoker"]

CATEGORICAL = {"sex_at_birth", "family_history", "physical_activity", "smoker",
               "known_high_bp", "on_bp_meds", "history_high_glucose"}


def _fit_score(train: pd.DataFrame, test: pd.DataFrame, features: list[str]) -> dict:
    features = [f for f in features if f in train.columns and train[f].notna().any()]
    cats = [f for f in features if f in CATEGORICAL]

    def prep(df: pd.DataFrame) -> pd.DataFrame:
        X = df[features].copy().reset_index(drop=True)
        for c in cats:
            X[c] = X[c].astype("category")
        return X

    y_tr = np.ascontiguousarray(train[LABEL].to_numpy(dtype=np.float64))
    n_neg, n_pos = int((y_tr == 0).sum()), int((y_tr == 1).sum())

    model = lgb.LGBMClassifier(
        objective="binary", n_estimators=300, learning_rate=0.05, num_leaves=31,
        min_child_samples=40, subsample=0.85, subsample_freq=1, colsample_bytree=0.85,
        reg_lambda=1.0, scale_pos_weight=n_neg / max(n_pos, 1),
        random_state=SEED, n_jobs=-1, verbose=-1,
    )
    model.fit(prep(train), y_tr, categorical_feature=cats)

    p = model.predict_proba(prep(test))[:, 1]
    y_te = test[LABEL].to_numpy()

    importances = sorted(zip(features, model.feature_importances_),
                         key=lambda kv: -kv[1])
    return {
        "features": features,
        "auc_roc": float(roc_auc_score(y_te, p)),
        "auc_pr": float(average_precision_score(y_te, p)),
        "top_importances": [(f, int(v)) for f, v in importances[:8]],
        "_model": model,
        "_preds": p,
    }


def audit(df: pd.DataFrame, name: str) -> dict:
    train, test = train_test_split(df, test_size=0.25, stratify=df[LABEL], random_state=SEED)

    print(f"\n{'=' * 72}\n{name}  —  {len(df):,} rows, {df[LABEL].mean():.2%} positive\n{'=' * 72}")

    without = _fit_score(train, test, CLEAN)
    with_all = _fit_score(train, test, CLEAN + SUSPECTS)

    print(f"  without suspects : AUC {without['auc_roc']:.4f}   AUC-PR {without['auc_pr']:.4f}")
    print(f"  with    suspects : AUC {with_all['auc_roc']:.4f}   AUC-PR {with_all['auc_pr']:.4f}")
    print(f"  delta            : {with_all['auc_roc'] - without['auc_roc']:+.4f}")

    # Per-feature contribution, added one at a time to the clean set.
    per_feature = {}
    print("\n  added individually to the clean feature set:")
    for s in SUSPECTS:
        if s not in df.columns or df[s].notna().sum() == 0:
            print(f"    {s:24s} not present in this dataset")
            continue
        r = _fit_score(train, test, CLEAN + [s])
        delta = r["auc_roc"] - without["auc_roc"]
        per_feature[s] = {"auc_roc": r["auc_roc"], "delta": delta}
        print(f"    {s:24s} AUC {r['auc_roc']:.4f}   {delta:+.4f}")

    # The number that actually matters: how the with-suspects model performs on
    # people who have NEVER been screened — our target user. If it degrades
    # sharply, the features were encoding healthcare contact, not physiology.
    realistic = None
    if "history_high_glucose" in test.columns:
        naive = test["history_high_glucose"].eq(False) & test["known_high_bp"].eq(False)
        if naive.sum() > 500 and test.loc[naive, LABEL].nunique() > 1:
            mask = naive.to_numpy()
            auc_naive_with = float(roc_auc_score(test.loc[naive, LABEL], with_all["_preds"][mask]))
            auc_naive_without = float(roc_auc_score(test.loc[naive, LABEL], without["_preds"][mask]))
            realistic = {
                "n": int(naive.sum()),
                "with_suspects": auc_naive_with,
                "without_suspects": auc_naive_without,
            }
            print(f"\n  on the {naive.sum():,} never-screened users (the target user):")
            print(f"    with suspects    : AUC {auc_naive_with:.4f}")
            print(f"    without suspects : AUC {auc_naive_without:.4f}")
            print(f"    the with-model's apparent advantage {'survives' if auc_naive_with - auc_naive_without > 0.01 else 'VANISHES'} here")

    for r in (without, with_all):
        r.pop("_model", None)
        r.pop("_preds", None)
    return {"dataset": name, "n": len(df), "positive_rate": float(df[LABEL].mean()),
            "without_suspects": without, "with_suspects": with_all,
            "per_feature": per_feature, "never_screened": realistic}


def main() -> int:
    data = load_all()
    results = []
    for key in ("brfss", "nhanes"):
        if key in data:
            results.append(audit(data[key], key.upper()))

    print(f"\n{'=' * 72}\nDECISION\n{'=' * 72}")
    decisions = {}
    for s in SUSPECTS:
        deltas = [r["per_feature"].get(s, {}).get("delta") for r in results]
        deltas = [d for d in deltas if d is not None]
        if not deltas:
            decisions[s] = "no_data"
            continue
        worst = max(deltas)
        # A feature that buys a large apparent gain is the most suspicious, not
        # the most valuable: it means the model is leaning on healthcare contact.
        if worst >= 0.02:
            decisions[s] = "exclude"
            verdict = f"EXCLUDE — buys {worst:+.4f} AUC by encoding healthcare contact"
        elif worst >= 0.005:
            decisions[s] = "clinical_score_only"
            verdict = f"CLINICAL SCORE ONLY — {worst:+.4f} AUC, keep as FINDRISC/ADA input"
        else:
            decisions[s] = "allow"
            verdict = f"ALLOW — {worst:+.4f} AUC, no meaningful leakage signal"
        print(f"  {s:24s} {verdict}")

    out = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "results": results,
        "decisions": decisions,
    }
    path = REPO_ROOT / "ml" / "reports" / "leakage_audit.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(out, indent=2), encoding="utf-8")
    print(f"\nWrote {path.relative_to(REPO_ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
