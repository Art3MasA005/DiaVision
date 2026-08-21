"""Weekly patterns and the clinician report — PRD §F8, §F9.

Three rules shape everything here, and they are the reason this is rule-based
rather than generative:

  **Never assert causation.** "often follows", never "causes". These are
  correlations in a single person's self-reported log, with no control and no
  randomisation. The wording has to stay honest about that.

  **A pattern needs enough evidence.** [MIN_OBSERVATIONS] data points before
  anything ships as an insight. Below that the honest output is "not enough
  yet", which is also what the empty state says.

  **Every card names its evidence.** An insight the user cannot check is an
  assertion, not an insight. Each carries the count it was computed from.

The report is the artefact a patient hands a doctor, so it carries the basis
line and the validation status too — the same honesty the risk screen owes.
"""

from __future__ import annotations

import statistics
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Any

# Below this a pattern is noise. PRD §F8.
MIN_OBSERVATIONS = 5


@dataclass
class Insight:
    key: str
    headline: str
    detail: str
    # What this was computed from, so the card can show its own evidence.
    observations: int
    direction: str = "flat"  # 'up' | 'down' | 'flat'

    def to_dict(self) -> dict[str, Any]:
        return {
            "key": self.key,
            "headline": self.headline,
            "detail": self.detail,
            "observations": self.observations,
            "direction": self.direction,
        }


@dataclass
class WeeklyInsights:
    period_start: date
    period_end: date
    insights: list[Insight] = field(default_factory=list)
    # True when nothing cleared MIN_OBSERVATIONS. The client shows the empty
    # state, which explains what to log rather than apologising.
    insufficient_data: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "period_start": self.period_start.isoformat(),
            "period_end": self.period_end.isoformat(),
            "insights": [i.to_dict() for i in self.insights],
            "insufficient_data": self.insufficient_data,
            "minimum_observations": MIN_OBSERVATIONS,
        }


def _trend(values: list[float]) -> str:
    """Direction of a short series, by comparing its halves.

    A least-squares slope on seven noisy self-reported points would imply more
    rigour than the data supports; halves are honest about being a rough read.
    """
    if len(values) < 4:
        return "flat"
    half = len(values) // 2
    first, second = statistics.fmean(values[:half]), statistics.fmean(values[half:])
    if first == 0:
        return "flat"
    change = (second - first) / abs(first)
    if change > 0.05:
        return "up"
    if change < -0.05:
        return "down"
    return "flat"


def weekly_insights(
    *,
    period_end: date,
    daily_kcal: dict[date, float],
    daily_gl: dict[date, float],
    daily_steps: dict[date, int],
    checkins: list[dict[str, Any]],
    glucose_readings: list[dict[str, Any]],
    days: int = 7,
) -> WeeklyInsights:
    """Patterns from this person's own logs only. Nothing comes from elsewhere."""
    period_start = period_end - timedelta(days=days - 1)
    out: list[Insight] = []

    # ── energy intake ────────────────────────────────────────────────
    kcal_values = [v for _, v in sorted(daily_kcal.items()) if v > 0]
    if len(kcal_values) >= MIN_OBSERVATIONS:
        direction = _trend(kcal_values)
        mean = statistics.fmean(kcal_values)
        out.append(Insight(
            key="intake",
            headline={
                "up": "You ate a little more this week",
                "down": "You ate a little less this week",
                "flat": "A steadier week than the last one",
            }[direction],
            detail=(f"Averaging about {int(round(mean))} kcal across "
                    f"{len(kcal_values)} logged days."),
            observations=len(kcal_values),
            direction=direction,
        ))

    # ── glycemic load ────────────────────────────────────────────────
    gl_values = [v for _, v in sorted(daily_gl.items()) if v > 0]
    if len(gl_values) >= MIN_OBSERVATIONS:
        high_days = [v for v in gl_values if v > 100]
        if high_days:
            out.append(Insight(
                key="glycemic_load",
                headline="Some days carried a heavier load",
                detail=(f"{len(high_days)} of {len(gl_values)} logged days went above "
                        f"a moderate glycemic load. A smaller rice portion is usually "
                        f"the single biggest lever."),
                observations=len(gl_values),
                direction=_trend(gl_values),
            ))

    # ── movement ─────────────────────────────────────────────────────
    step_values = [v for _, v in sorted(daily_steps.items()) if v > 0]
    if len(step_values) >= MIN_OBSERVATIONS:
        direction = _trend([float(v) for v in step_values])
        out.append(Insight(
            key="activity",
            headline={
                "up": "You moved more this week",
                "down": "You moved less this week",
                "flat": "Your movement held steady",
            }[direction],
            detail=(f"About {int(round(statistics.fmean(step_values)))} steps a day "
                    f"across {len(step_values)} days. Activity is one of only four "
                    f"things the clinical score reads."),
            observations=len(step_values),
            direction=direction,
        ))

    # ── sleep against energy ─────────────────────────────────────────
    paired = [
        (c["sleep_hours"], c["energy"]) for c in checkins
        if c.get("sleep_hours") is not None and c.get("energy") is not None
    ]
    if len(paired) >= MIN_OBSERVATIONS:
        short = [e for s, e in paired if s < 6.5]
        long_ = [e for s, e in paired if s >= 6.5]
        if short and long_ and statistics.fmean(long_) - statistics.fmean(short) >= 0.5:
            # "often follows", never "causes" — this is a correlation in one
            # person's self-report, and the wording must not outrun it.
            out.append(Insight(
                key="sleep_energy",
                headline="Lower energy often follows a shorter night",
                detail=("On nights under about 6.5 hours your next-day energy tends "
                        "to be rated lower. This is a pattern in your own log, not "
                        "a cause."),
                observations=len(paired),
                direction="flat",
            ))

    # ── glucose spread ───────────────────────────────────────────────
    fasting = [
        r["value"] for r in glucose_readings
        if r.get("context_tag") == "fasting" and r.get("value") is not None
    ]
    if len(fasting) >= MIN_OBSERVATIONS:
        out.append(Insight(
            key="fasting_glucose",
            headline="Your fasting readings this week",
            detail=(f"{len(fasting)} readings, from {min(fasting):.1f} to "
                    f"{max(fasting):.1f} mmol/L. Take the spread to your doctor "
                    f"rather than any single number."),
            observations=len(fasting),
            direction=_trend(fasting),
        ))

    return WeeklyInsights(
        period_start=period_start,
        period_end=period_end,
        insights=out,
        insufficient_data=not out,
    )


# ── the clinician report ──────────────────────────────────────────────

def build_report(
    *,
    period_start: date,
    period_end: date,
    profile_name: str,
    age: int | None,
    sex: str | None,
    latest_risk: dict[str, Any] | None,
    daily_kcal: dict[date, float],
    daily_gl: dict[date, float],
    daily_steps: dict[date, int],
    glucose_readings: list[dict[str, Any]],
    weight_readings: list[dict[str, Any]],
    insights: WeeklyInsights,
) -> dict[str, Any]:
    """A summary a clinician can read in thirty seconds.

    Carries the basis line and the validation status, because a report that
    quotes a risk figure without saying what produced it is worse than no
    report — the doctor cannot tell how much to trust it.
    """
    def _series(readings: list[dict[str, Any]]) -> dict[str, Any] | None:
        values = [r["value"] for r in readings if r.get("value") is not None]
        if not values:
            return None
        return {
            "n": len(values),
            "min": round(min(values), 2),
            "max": round(max(values), 2),
            "mean": round(statistics.fmean(values), 2),
            "latest": round(values[-1], 2),
        }

    logged_days = len([v for v in daily_kcal.values() if v > 0])

    risk_block: dict[str, Any] | None = None
    if latest_risk:
        risk_block = {
            # A range, never a point value — the same rule the risk screen holds.
            "range_low": latest_risk.get("range_low"),
            "range_high": latest_risk.get("range_high"),
            "band": latest_risk.get("band"),
            "band_label": latest_risk.get("band_label"),
            "taken_at": latest_risk.get("taken_at"),
            "basis": latest_risk.get("basis"),
            "clinical_score": latest_risk.get("clinical_score"),
            "clinical_points": latest_risk.get("clinical_points"),
            "clinical_max": latest_risk.get("clinical_max"),
            "validation_status": latest_risk.get("validation_status"),
        }

    return {
        "generated_for": profile_name,
        "age_years": age,
        "sex_at_birth": sex,
        "period": {
            "start": period_start.isoformat(),
            "end": period_end.isoformat(),
            "days_logged": logged_days,
        },
        "risk": risk_block,
        "intake": {
            "days_logged": logged_days,
            "mean_kcal": (round(statistics.fmean([v for v in daily_kcal.values() if v > 0]))
                          if logged_days else None),
            "mean_glycemic_load": (round(statistics.fmean(
                [v for v in daily_gl.values() if v > 0]), 1)
                if any(v > 0 for v in daily_gl.values()) else None),
        },
        "activity": {
            "days_logged": len([v for v in daily_steps.values() if v > 0]),
            "mean_steps": (round(statistics.fmean(
                [v for v in daily_steps.values() if v > 0]))
                if any(v > 0 for v in daily_steps.values()) else None),
        },
        "glucose_mmol_l": _series(glucose_readings),
        "weight_kg": _series(weight_readings),
        "patterns": [i.to_dict() for i in insights.insights],
        # Restated inside the artefact itself, because a printed or shared
        # report travels away from the app that framed it.
        "disclaimer": (
            "This summary is generated from a person's own self-reported logs "
            "and a statistical screening estimate. It is not a diagnosis and "
            "not a substitute for clinical assessment."
        ),
    }
