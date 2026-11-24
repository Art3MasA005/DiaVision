"""Everything the coach is allowed to know about one profile.

The coach reads the user's data **directly from the database**, so the user
never has to paste a reading or retype their weight into the chat. This module
builds that picture: profile, latest risk estimate, labs and vitals, meals,
check-ins, activity and today's targets.

Two guarantees, both structural rather than promised:

  * **One profile only.** Every query is keyed by `profile_id` and runs inside
    the caller's RLS-scoped session, so another account's rows cannot reach
    the model even if a query here were wrong.
  * **Only what was logged.** Nothing is inferred or filled in. A section with
    no data says "nothing logged" — the model is told to treat that as unknown
    rather than guess.

The snapshot goes to the model as plain text. Plain text, not JSON, because a
labelled list is what the model reads most reliably and it is far shorter.
"""

from __future__ import annotations

import uuid
from collections import defaultdict
from datetime import date, timedelta
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db.models import (
    Account, ActivityLog, CoachMessage, DailyCheckin, HealthProfile, MealLog,
    Profile, RiskAssessment, VitalLog,
)

MEAL_DAYS = 7
ROUTINE_DAYS = 14
VITAL_DAYS = 120
HISTORY_TURNS = 12


def _age(dob: date | None, today: date) -> int | None:
    if dob is None:
        return None
    return today.year - dob.year - ((today.month, today.day) < (dob.month, dob.day))


def _fmt(value: Any, unit: str = "") -> str:
    if value is None:
        return "not recorded"
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, float):
        value = round(value, 1)
    return f"{value}{unit}"


def build(session: Session, profile: Profile, *,
          target: dict | None = None,
          today: date | None = None) -> dict[str, Any]:
    """Collect this profile's data.

    Returns a dict with:
      `text`     the snapshot as the model will read it
      `sections` the names of sections that actually hold data (for `cited`)
      `history`  the recent conversation as `[{"role", "content"}]`
      plus the summary figures the fixed-wording fallback uses.
    """
    today = today or date.today()
    pid: uuid.UUID = profile.id
    lines: list[str] = []
    sections: list[str] = []

    account = session.get(Account, profile.account_id_owner)
    health = session.get(HealthProfile, pid)

    # ── profile ───────────────────────────────────────────────────────
    lines.append(f"TODAY: {today.isoformat()}")
    lines.append("")
    lines.append("PROFILE")
    lines.append(f"- name: {profile.display_name}")
    lines.append(f"- app language: {getattr(account, 'locale', None) or 'en'}")
    lines.append(f"- region: {profile.region_pack}")
    if health is not None:
        sections.append("your profile")
        bmi = None
        if health.weight_kg and health.height_cm:
            bmi = health.weight_kg / (health.height_cm / 100) ** 2
        lines += [
            f"- age: {_fmt(_age(health.dob, today), ' years')}",
            f"- sex at birth: {_fmt(health.sex_at_birth)}",
            f"- height: {_fmt(health.height_cm, ' cm')}",
            f"- weight: {_fmt(health.weight_kg, ' kg')}",
            f"- BMI: {_fmt(bmi)}",
            f"- waist: {_fmt(health.waist_cm, ' cm')}",
            f"- family history of diabetes: {_fmt(health.family_history)}",
            f"- usual physical activity: {_fmt(health.physical_activity)}",
            f"- smoker: {_fmt(health.smoker)}",
            f"- known high blood pressure: {_fmt(health.known_high_bp)}",
            f"- on blood-pressure medicine: {_fmt(health.on_bp_meds)}",
            f"- ever told blood sugar was high: {_fmt(health.history_high_glucose)}",
            f"- gestational diabetes history: {_fmt(health.gestational_diabetes_history)}",
            f"- diabetes status (self-reported): {_fmt(health.diabetes_status)}",
            f"- other conditions: {', '.join(health.conditions or []) or 'none recorded'}",
            f"- allergies: {', '.join(health.allergies or []) or 'none recorded'}",
            f"- dietary preferences: {', '.join(health.dietary_prefs or []) or 'none recorded'}",
            f"- goal: {_fmt(health.goal_type)}"
            + (f" (goal weight {round(health.goal_weight_kg, 1)} kg)"
               if health.goal_weight_kg else ""),
        ]
    else:
        lines.append("- health profile: not filled in yet")

    # ── risk ──────────────────────────────────────────────────────────
    risks = list(session.scalars(
        select(RiskAssessment).where(RiskAssessment.profile_id == pid)
        .order_by(RiskAssessment.taken_at.desc()).limit(6)
    ))
    lines.append("")
    lines.append("DIABETES RISK ESTIMATE (a statistical screening estimate, never a diagnosis)")
    latest_risk_range: str | None = None
    if risks:
        sections.append("your last assessment")
        r = risks[0]
        latest_risk_range = (f"{round(r.confidence_low * 100)}–"
                             f"{round(r.confidence_high * 100)}%")
        lines += [
            f"- latest: {latest_risk_range} chance of undetected high blood sugar, "
            f"band '{r.risk_band}', taken {r.taken_at.date().isoformat()}, tier {r.tier}",
            f"- clinical score: {r.clinical_score} ({r.clinical_points} points)",
        ]
        factors = r.top_factors_json or {}
        for kind, label in (("modifiable", "factors the user can change"),
                            ("fixed", "factors the user cannot change")):
            items = factors.get(kind) if isinstance(factors, dict) else None
            if items:
                names = [
                    f"{f.get('label')} (+{f.get('points')})" if isinstance(f, dict) else str(f)
                    for f in items[:5]
                ]
                lines.append(f"- {label}: {', '.join(names)}")
        if len(risks) > 1:
            trail = "; ".join(
                f"{x.taken_at.date().isoformat()}: {round(x.confidence_low * 100)}–"
                f"{round(x.confidence_high * 100)}%"
                for x in reversed(risks)
            )
            lines.append(f"- history (oldest first): {trail}")
    else:
        lines.append("- no assessment completed yet")

    # ── targets ───────────────────────────────────────────────────────
    lines.append("")
    lines.append("TODAY'S TARGETS (already through the app's safety limits)")
    if target:
        lines.append(
            f"- {target.get('kcal')} kcal, carbs {target.get('carbs_g')} g, "
            f"protein {target.get('protein_g')} g, fat {target.get('fat_g')} g, "
            f"fibre {target.get('fibre_g')} g, glycemic-load ceiling "
            f"{target.get('glycemic_load_ceiling')}"
        )
        if target.get("weight_loss_disabled"):
            lines.append("- weight-loss targets are switched off for safety; maintenance only")
    else:
        lines.append("- no target (health profile incomplete)")

    # ── labs and vitals ───────────────────────────────────────────────
    vitals = list(session.scalars(
        select(VitalLog).where(
            VitalLog.profile_id == pid,
            VitalLog.recorded_at >= _start_of(today - timedelta(days=VITAL_DAYS)),
        ).order_by(VitalLog.recorded_at.desc()).limit(200)
    ))
    lines.append("")
    lines.append(f"LABS AND VITALS (last {VITAL_DAYS} days, newest first)")
    latest_glucose: float | None = None
    if vitals:
        sections.append("your readings")
        by_type: dict[str, list[VitalLog]] = defaultdict(list)
        for v in vitals:
            by_type[v.type].append(v)
        for vtype, rows in by_type.items():
            shown = ", ".join(
                f"{round(v.value, 1)} {v.unit}"
                + (f" ({v.context_tag})" if v.context_tag else "")
                + f" on {v.recorded_at.date().isoformat()}"
                for v in rows[:10]
            )
            lines.append(f"- {vtype}: {shown}")
        if by_type.get("glucose"):
            latest_glucose = round(by_type["glucose"][0].value, 1)
    else:
        lines.append("- nothing logged")

    # ── meals ─────────────────────────────────────────────────────────
    meals = list(session.scalars(
        select(MealLog).where(
            MealLog.profile_id == pid,
            MealLog.eaten_on >= today - timedelta(days=MEAL_DAYS - 1),
        ).order_by(MealLog.eaten_at)
    ))
    lines.append("")
    lines.append(f"MEALS (last {MEAL_DAYS} days; calories are estimates)")
    day_kcal: dict[date, float] = defaultdict(float)
    if meals:
        sections.append("your logged meals")
        by_day: dict[date, list[MealLog]] = defaultdict(list)
        for m in meals:
            by_day[m.eaten_on].append(m)
        for day in sorted(by_day):
            day_meals = by_day[day]
            kcal = sum(i.kcal for m in day_meals for i in m.items)
            carbs = sum(i.carbs_g for m in day_meals for i in m.items)
            gls = [i.glycemic_load for m in day_meals for i in m.items
                   if i.glycemic_load is not None]
            day_kcal[day] = kcal
            lines.append(
                f"- {day.isoformat()}: about {round(kcal)} kcal, {round(carbs)} g carbs"
                + (f", glycemic load {round(sum(gls))}" if gls else "")
            )
            for m in day_meals:
                food = ", ".join(
                    f"{i.name_snapshot} {_qty(i.quantity)} {i.unit} (~{round(i.kcal)} kcal)"
                    for i in m.items
                )
                lines.append(f"    {m.slot}: {food or 'no items'}")
    else:
        lines.append("- nothing logged")

    # ── check-ins ─────────────────────────────────────────────────────
    checkins = list(session.scalars(
        select(DailyCheckin).where(
            DailyCheckin.profile_id == pid,
            DailyCheckin.checkin_on >= today - timedelta(days=ROUTINE_DAYS - 1),
        ).order_by(DailyCheckin.checkin_on)
    ))
    lines.append("")
    lines.append(f"DAILY CHECK-INS (last {ROUTINE_DAYS} days; energy and mood are 1–5)")
    if checkins:
        sections.append("your check-ins")
        for c in checkins:
            lines.append(
                f"- {c.checkin_on.isoformat()}: energy {_fmt(c.energy)}, "
                f"sleep {_fmt(c.sleep_hours, ' h')}, mood {_fmt(c.mood)}"
                + (f", symptoms: {', '.join(c.symptoms)}" if c.symptoms else "")
            )
    else:
        lines.append("- nothing logged")

    # ── activity ──────────────────────────────────────────────────────
    activity = list(session.scalars(
        select(ActivityLog).where(
            ActivityLog.profile_id == pid,
            ActivityLog.activity_on >= today - timedelta(days=ROUTINE_DAYS - 1),
        ).order_by(ActivityLog.activity_on)
    ))
    lines.append("")
    lines.append(f"ACTIVITY (last {ROUTINE_DAYS} days)")
    if activity:
        sections.append("your activity log")
        for a in activity:
            lines.append(
                f"- {a.activity_on.isoformat()}: {a.steps} steps, "
                f"{a.active_minutes} active minutes"
                + (f", {round(a.distance_km, 1)} km" if a.distance_km else "")
            )
    else:
        lines.append("- nothing logged")

    # ── conversation so far ───────────────────────────────────────────
    turns = list(reversed(list(session.scalars(
        select(CoachMessage).where(CoachMessage.profile_id == pid)
        .order_by(CoachMessage.created_at.desc()).limit(HISTORY_TURNS)
    ))))
    history = [
        {"role": "user" if t.role == "user" else "assistant", "content": t.body}
        for t in turns
    ]

    kcal_days = [k for k in day_kcal.values() if k]
    steps = [a.steps for a in activity]
    return {
        "text": "\n".join(lines),
        "sections": sections,
        "history": history,
        "locale": getattr(account, "locale", None) or "en",
        # The fixed-wording fallback's inputs.
        "mean_kcal": sum(kcal_days) / len(kcal_days) if kcal_days else None,
        "mean_steps": sum(steps) / len(steps) if steps else None,
        "latest_glucose": latest_glucose,
        "latest_risk_range": latest_risk_range,
        "days_logged": len(kcal_days),
    }


def _qty(q: float) -> str:
    return str(int(q)) if float(q).is_integer() else f"{q:g}"


def _start_of(day: date):
    from datetime import datetime, time, timezone
    return datetime.combine(day, time.min, tzinfo=timezone.utc)
