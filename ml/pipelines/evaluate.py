"""Honest evaluation. Accuracy is not reported here, and that is deliberate.

Playbook §B5: on a 14%-positive dataset, predicting "nobody has diabetes" scores
86% accuracy. Any metric that rewards that is worse than useless in a product
that shows users a percentage.

What we report instead, in rough order of how much it matters to this product:

  1. Calibration — Brier, ECE, reliability curve. THE metric. If the app says
     20%, then 20 of every 100 such users must actually have it. A model that
     ranks perfectly but is miscalibrated is lying to the user in a way they
     cannot detect.
  2. Sensitivity at a fixed specificity — the shipped operating point. Missing
     a diabetic person is much worse than sending a healthy one for a cheap
     blood test.
  3. AUC-PR — more honest than AUC-ROC under class imbalance.
  4. AUC-ROC — reported because everyone expects it, not because it is best.
  5. Per-subgroup breakdowns — a model at 0.84 overall can be 0.61 for women
     over 60, and the aggregate number hides that completely.
"""

from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Any

import numpy as np
from sklearn.metrics import (
    average_precision_score, brier_score_loss, roc_auc_score, roc_curve,
)


@dataclass
class CalibrationBin:
    lower: float
    upper: float
    count: int
    mean_predicted: float
    observed_rate: float


@dataclass
class Metrics:
    n: int
    n_positive: int
    positive_rate: float

    auc_roc: float
    auc_pr: float
    brier: float
    ece: float

    sensitivity_at_target: float
    specificity_at_target: float
    threshold_at_target: float
    target_sensitivity: float

    reliability: list[CalibrationBin] = field(default_factory=list)
    subgroups: dict[str, dict[str, Any]] = field(default_factory=dict)
    warnings: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["reliability"] = [asdict(b) for b in self.reliability]
        return d


def expected_calibration_error(y: np.ndarray, p: np.ndarray, bins: int = 10
                               ) -> tuple[float, list[CalibrationBin]]:
    """ECE plus the reliability curve, using equal-width probability bins.

    Equal-width rather than equal-count because the reliability curve is drawn
    on a probability axis and a user reading it expects even spacing.
    """
    edges = np.linspace(0.0, 1.0, bins + 1)
    total = len(y)
    ece = 0.0
    curve: list[CalibrationBin] = []

    for i in range(bins):
        lo, hi = edges[i], edges[i + 1]
        mask = (p >= lo) & (p < hi) if i < bins - 1 else (p >= lo) & (p <= hi)
        count = int(mask.sum())
        if count == 0:
            continue
        mean_p = float(p[mask].mean())
        observed = float(y[mask].mean())
        ece += (count / total) * abs(mean_p - observed)
        curve.append(CalibrationBin(round(lo, 3), round(hi, 3), count,
                                    round(mean_p, 4), round(observed, 4)))
    return ece, curve


def sensitivity_at_specificity(y: np.ndarray, p: np.ndarray, min_specificity: float
                               ) -> tuple[float, float, float]:
    """Best sensitivity achievable while holding specificity at or above the floor."""
    fpr, tpr, thresholds = roc_curve(y, p)
    specificity = 1.0 - fpr
    ok = specificity >= min_specificity
    if not ok.any():
        return 0.0, 0.0, 1.0
    idx = int(np.argmax(np.where(ok, tpr, -1.0)))
    return float(tpr[idx]), float(specificity[idx]), float(thresholds[idx])


def threshold_for_sensitivity(y: np.ndarray, p: np.ndarray, target_sensitivity: float
                              ) -> tuple[float, float, float]:
    """Lowest threshold reaching the target sensitivity, and what it costs in specificity.

    This is the direction the product actually cares about: fix how many
    diabetic people we are willing to miss, then see what specificity we get.
    """
    fpr, tpr, thresholds = roc_curve(y, p)
    ok = tpr >= target_sensitivity
    if not ok.any():
        return float(tpr[-1]), float(1.0 - fpr[-1]), float(thresholds[-1])
    idx = int(np.argmax(ok))  # first index meeting the target
    return float(tpr[idx]), float(1.0 - fpr[idx]), float(thresholds[idx])


def _safe_auc(y: np.ndarray, p: np.ndarray) -> float | None:
    if len(np.unique(y)) < 2:
        return None
    return float(roc_auc_score(y, p))


def subgroup_metrics(y: np.ndarray, p: np.ndarray, groups: dict[str, np.ndarray],
                     min_count: int = 100) -> dict[str, dict[str, Any]]:
    """Per-subgroup AUC and calibration.

    PRD §7.4b makes this non-negotiable at international scale. Subgroups below
    `min_count` report their size but no metrics — a confident-looking AUC from
    40 people is noise being presented as a finding.
    """
    out: dict[str, dict[str, Any]] = {}
    for dimension, values in groups.items():
        out[dimension] = {}
        for level in sorted(set(map(str, values))):
            mask = np.asarray([str(v) == level for v in values])
            count = int(mask.sum())
            if count < min_count:
                out[dimension][level] = {"n": count, "note": "too few to report"}
                continue
            yg, pg = y[mask], p[mask]
            ece, _ = expected_calibration_error(yg, pg)
            out[dimension][level] = {
                "n": count,
                "positive_rate": round(float(yg.mean()), 4),
                "auc_roc": None if _safe_auc(yg, pg) is None else round(_safe_auc(yg, pg), 4),
                "brier": round(float(brier_score_loss(yg, pg)), 4),
                "ece": round(ece, 4),
            }
    return out


def evaluate(y, p, groups: dict[str, np.ndarray] | None = None,
             target_sensitivity: float = 0.85, min_specificity: float = 0.60,
             leakage_alarm_auc: float = 0.95) -> Metrics:
    y = np.asarray(y).astype(int)
    p = np.asarray(p, dtype=float)

    ece, curve = expected_calibration_error(y, p)
    sens, spec, thr = threshold_for_sensitivity(y, p, target_sensitivity)
    auc = _safe_auc(y, p) or 0.0

    warnings: list[str] = []
    if auc >= leakage_alarm_auc:
        warnings.append(
            f"AUC {auc:.4f} >= {leakage_alarm_auc} on questionnaire data. Playbook §B0: "
            f"this is almost certainly leakage, not success. Do not ship; go find the bug."
        )
    if spec < min_specificity:
        warnings.append(
            f"At {target_sensitivity:.0%} sensitivity, specificity is only {spec:.1%} "
            f"(target >= {min_specificity:.0%}). The model would send too many healthy "
            f"users for testing."
        )
    if ece > 0.05:
        warnings.append(
            f"ECE {ece:.4f} is high. The displayed percentage would be misleading — "
            f"calibration matters more than ranking for this product."
        )

    return Metrics(
        n=len(y),
        n_positive=int(y.sum()),
        positive_rate=round(float(y.mean()), 4),
        auc_roc=round(auc, 4),
        auc_pr=round(float(average_precision_score(y, p)), 4),
        brier=round(float(brier_score_loss(y, p)), 4),
        ece=round(ece, 4),
        sensitivity_at_target=round(sens, 4),
        specificity_at_target=round(spec, 4),
        threshold_at_target=round(thr, 4),
        target_sensitivity=target_sensitivity,
        reliability=curve,
        subgroups=subgroup_metrics(y, p, groups) if groups else {},
        warnings=warnings,
    )


def format_report(m: Metrics, title: str = "") -> str:
    lines: list[str] = []
    if title:
        lines += [title, "=" * len(title)]
    lines.append(f"  n = {m.n:,}   positives = {m.n_positive:,} ({m.positive_rate:.1%})")
    lines.append("")
    lines.append("  Discrimination")
    lines.append(f"    AUC-ROC                {m.auc_roc:.4f}")
    lines.append(f"    AUC-PR                 {m.auc_pr:.4f}   (more honest under imbalance)")
    lines.append("")
    lines.append("  Calibration  <- the metric that matters most here")
    lines.append(f"    Brier score            {m.brier:.4f}   (lower is better)")
    lines.append(f"    ECE                    {m.ece:.4f}   (mean gap between stated and actual)")
    lines.append("")
    lines.append("  Operating point")
    lines.append(f"    sensitivity            {m.sensitivity_at_target:.1%}  (target {m.target_sensitivity:.0%})")
    lines.append(f"    specificity there      {m.specificity_at_target:.1%}")
    lines.append(f"    threshold              {m.threshold_at_target:.4f}")

    if m.reliability:
        lines += ["", "  Reliability (stated vs actual)"]
        for b in m.reliability:
            bar = "#" * max(1, round(b.observed_rate * 40))
            lines.append(f"    {b.lower:.1f}-{b.upper:.1f}  n={b.count:>6,}  "
                         f"said {b.mean_predicted:.3f}  actual {b.observed_rate:.3f}  {bar}")

    if m.subgroups:
        lines += ["", "  Per subgroup"]
        for dimension, levels in m.subgroups.items():
            lines.append(f"    {dimension}")
            for level, stats in levels.items():
                if "note" in stats:
                    lines.append(f"      {level:<14} n={stats['n']:>6,}  {stats['note']}")
                else:
                    lines.append(f"      {level:<14} n={stats['n']:>6,}  "
                                 f"AUC {stats['auc_roc']}  ECE {stats['ece']}")

    if m.warnings:
        lines += ["", "  WARNINGS"]
        for w in m.warnings:
            lines.append(f"    ! {w}")
    return "\n".join(lines)
