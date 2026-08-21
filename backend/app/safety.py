"""Safety rails and the red-flag interceptor. PRD §3.3 and §5.4.

Two separate mechanisms, both hard-coded rather than AI-decided:

  RED FLAGS (§3.3)   values or words that must interrupt whatever the user was
                     doing and show emergency guidance instead. Runs as
                     middleware on /vitals, /checkins and /coach/message.

  NUTRITION RAILS    absolute floors on any calorie or weight-loss target.
  (§5.4)             Nobody may override these — not the user, not a clinician,
                     not a region pack. A clinician may widen a band within the
                     documented range; the floors themselves are immovable.

These are pure functions on purpose. They have no database and no network, so
they are trivially testable against adversarial inputs, which PRD §18 requires
before release.

A region pack may make a threshold STRICTER, never looser; enforced both here
and in ml/scripts/validate_packs.py.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from enum import Enum


class Severity(str, Enum):
    INFO = "info"
    WARNING = "warning"
    URGENT = "urgent"
    EMERGENCY = "emergency"


@dataclass
class SafetyCard:
    """A blocking card that REPLACES the normal response (PRD §3.3)."""

    trigger: str
    severity: Severity
    title: str
    body: str
    actions: list[str] = field(default_factory=list)
    suppress_ai: bool = True

    @property
    def blocks_response(self) -> bool:
        return self.severity in (Severity.URGENT, Severity.EMERGENCY)


# ── absolute limits. Not configurable. ────────────────────────────────

ABSOLUTE = {
    "min_kcal_female": 1200,
    "min_kcal_male": 1500,
    "max_deficit_kcal": 500,
    "max_weight_loss_kg_per_week": 1.0,
    "bmi_floor_weight_loss": 18.5,
    "disordered_eating_kcal": 800,
    "min_age": 18,
    # mmol/L — PRD §3.3
    "hypoglycaemia": 3.9,
    "fasting_urgent": 13.9,
    "random_urgent": 16.7,
}


# ── red-flag phrase detection ─────────────────────────────────────────
# Substring matching on purpose. A regex clever enough to avoid every false
# positive would also be clever enough to miss a real emergency, and the
# asymmetry of those two errors is not close: PRD §14 sets a target of ZERO
# false negatives on the golden set and says nothing about false positives.

EMERGENCY_PHRASES = {
    "cardiac": ["chest pain", "chest pressure", "pain in my chest", "বুকে ব্যথা"],
    "consciousness": ["unconscious", "passed out", "fainted", "unresponsive",
                      "can't wake", "cannot wake", "অজ্ঞান"],
    "confusion": ["confused", "disoriented", "slurred speech", "can't think straight"],
    "dka": ["fruity breath", "breath smells sweet", "vomiting and can't keep",
            "vomiting and cannot keep", "can't keep fluids", "cannot keep fluids",
            "deep breathing", "kussmaul"],
    "foot": ["foot ulcer", "black toe", "toe turned black", "wound won't heal",
             "wound will not heal", "gangrene", "পায়ে ঘা"],
    "vision": ["sudden vision loss", "lost my vision", "can't see", "cannot see",
               "went blind", "sudden blurred vision"],
}

CRISIS_PHRASES = [
    "kill myself", "suicide", "suicidal", "end my life", "want to die",
    "hurt myself", "harm myself", "self harm", "no reason to live",
    "আত্মহত্যা",
]


def _normalise(text: str) -> str:
    return re.sub(r"\s+", " ", text.lower().strip())


def check_text(message: str) -> SafetyCard | None:
    """Scan free text. Runs BEFORE the message reaches any model (PRD §F10)."""
    if not message:
        return None
    text = _normalise(message)

    # Crisis first — it outranks everything, including a simultaneous medical flag.
    for phrase in CRISIS_PHRASES:
        if phrase in text:
            return SafetyCard(
                trigger="self_harm",
                severity=Severity.EMERGENCY,
                title="You don't have to face this alone",
                body=("It sounds like you may be going through something very hard. "
                      "Please talk to someone who can help right now — a crisis line, "
                      "a doctor, or someone you trust."),
                actions=["Show crisis helplines", "Contact someone I trust"],
            )

    for category, phrases in EMERGENCY_PHRASES.items():
        for phrase in phrases:
            if phrase in text:
                return SafetyCard(
                    trigger=f"emergency:{category}",
                    severity=Severity.EMERGENCY,
                    title="This needs urgent medical attention",
                    body=("What you have described can be serious. Please contact a "
                          "doctor or emergency services now. This app cannot help "
                          "with an emergency."),
                    actions=["Call emergency services", "Find a doctor nearby"],
                )
    return None


def check_glucose(value_mmol_l: float, context: str | None = None,
                  thresholds: dict | None = None) -> SafetyCard | None:
    """Screen a user-entered glucose reading (PRD §3.3).

    `thresholds` comes from the region pack and may only tighten the defaults.
    """
    t = dict(ABSOLUTE)
    for key in ("hypoglycaemia", "fasting_urgent", "random_urgent"):
        supplied = (thresholds or {}).get(key)
        if supplied is None:
            continue
        # A pack may lower an upper bound or raise a lower bound; never the reverse.
        t[key] = min(t[key], supplied) if key != "hypoglycaemia" else max(t[key], supplied)

    if value_mmol_l < t["hypoglycaemia"]:
        return SafetyCard(
            trigger="hypoglycaemia",
            severity=Severity.URGENT,
            title="Your blood sugar is low",
            body=("Take about 15g of fast-acting carbohydrate now — glucose tablets, "
                  "half a glass of fruit juice, or sugar in water. Recheck in 15 "
                  "minutes. If it stays low or you feel worse, contact a doctor."),
            actions=["Recheck in 15 minutes", "Find a doctor"],
        )

    is_fasting = (context or "").lower() in ("fasting", "pre_meal", "bedtime")
    limit = t["fasting_urgent"] if is_fasting else t["random_urgent"]
    if value_mmol_l > limit:
        return SafetyCard(
            trigger="hyperglycaemia",
            severity=Severity.URGENT,
            title="These numbers are high",
            body=("This reading is high enough that a doctor should see it today. "
                  "Do not change any medication on your own."),
            actions=["Find a doctor", "Log how I'm feeling"],
        )
    return None


def check_profile(age: int | None = None, pregnant: bool = False,
                  conditions: list[str] | None = None) -> SafetyCard | None:
    """Profile-level gates that change what the whole app may do."""
    if age is not None and age < ABSOLUTE["min_age"]:
        return SafetyCard(
            trigger="under_18",
            severity=Severity.URGENT,
            title="This app is for adults",
            body=("DiaVision is designed for people aged 18 and over. "
                  "Please speak to a doctor about health questions."),
            actions=["Find a doctor"],
        )

    if pregnant:
        return SafetyCard(
            trigger="pregnancy",
            severity=Severity.WARNING,
            title="Let's involve your doctor",
            body=("During pregnancy, diet and blood sugar should be guided by your "
                  "doctor or obstetrician. We've turned off calorie targets and "
                  "weight-loss features."),
            actions=["Find a doctor"],
            suppress_ai=False,
        )

    blocking = {"ckd", "chronic kidney disease", "heart failure", "dialysis"}
    for condition in (conditions or []):
        if condition.lower().strip() in blocking:
            return SafetyCard(
                trigger=f"condition:{condition.lower().strip()}",
                severity=Severity.WARNING,
                title="Your doctor should set your targets",
                body=("With your medical history, diet targets need to come from "
                      "your doctor rather than an app. Tracking still works."),
                actions=["Find a doctor"],
                suppress_ai=False,
            )
    return None


# ── nutrition rails ───────────────────────────────────────────────────

@dataclass
class CalorieTarget:
    kcal: int
    was_clamped: bool
    reason: str | None = None
    weight_loss_disabled: bool = False


def clamp_calorie_target(requested_kcal: float, sex: str, tdee: float,
                         bmi: float | None = None) -> CalorieTarget:
    """Apply the §5.4 floors. Nobody overrides these — not even a clinician.

    PRD §3.6: "A wrong number typed once shouldn't be able to starve a patient."
    """
    floor = ABSOLUTE["min_kcal_female"] if sex == "female" else ABSOLUTE["min_kcal_male"]

    if bmi is not None and bmi < ABSOLUTE["bmi_floor_weight_loss"]:
        # Weight loss is off — but the absolute floor still applies. A small,
        # elderly, sedentary person can have a maintenance TDEE *below* the
        # floor (38kg at 145cm computes to about 930 kcal), and returning that
        # untouched would hand the most underweight users the lowest target in
        # the app. The floor is the safe direction here: someone below a
        # healthy BMI should not be eating at a computed minimum.
        target = max(float(tdee), float(floor))
        reason = (f"BMI {bmi:.1f} is below {ABSOLUTE['bmi_floor_weight_loss']}. "
                  f"Weight loss is disabled; target set to maintenance.")
        if target > tdee:
            reason += (f" Raised to the {floor} kcal/day floor for {sex}, which is "
                       f"above maintenance for this body size.")
        return CalorieTarget(
            kcal=int(round(target)), was_clamped=True, weight_loss_disabled=True,
            reason=reason,
        )

    target = float(requested_kcal)
    reasons: list[str] = []

    max_deficit_floor = tdee - ABSOLUTE["max_deficit_kcal"]
    if target < max_deficit_floor:
        target = max_deficit_floor
        reasons.append(f"deficit capped at {ABSOLUTE['max_deficit_kcal']} kcal/day below maintenance")

    if target < floor:
        target = floor
        reasons.append(f"absolute floor of {floor} kcal/day for {sex}")

    return CalorieTarget(
        kcal=int(round(target)),
        was_clamped=bool(reasons),
        reason="; ".join(reasons) if reasons else None,
    )


def check_disordered_eating(recent_daily_kcal: list[float],
                            goal_bmi: float | None = None) -> SafetyCard | None:
    """Detect restriction patterns. Never gamify this (PRD §5.4)."""
    very_low = [k for k in recent_daily_kcal if k < ABSOLUTE["disordered_eating_kcal"]]
    if len(very_low) >= 3:
        return SafetyCard(
            trigger="disordered_eating:low_intake",
            severity=Severity.WARNING,
            title="We're a bit concerned",
            body=("You've logged very low intake several times recently. Eating too "
                  "little can be harmful, especially with blood sugar. We've turned "
                  "off aggressive targets. If food feels difficult right now, talking "
                  "to a doctor can help."),
            actions=["Find a doctor", "Set a gentler goal"],
            suppress_ai=False,
        )

    if goal_bmi is not None and goal_bmi < ABSOLUTE["bmi_floor_weight_loss"]:
        return SafetyCard(
            trigger="disordered_eating:goal_bmi",
            severity=Severity.WARNING,
            title="That goal weight is below a healthy range",
            body=("The goal you've set works out below a healthy BMI. We can't set "
                  "that as a target, but we can help you aim for a healthy range."),
            actions=["Choose a healthy goal"],
            suppress_ai=False,
        )
    return None


def check_weight_anxiety(weigh_in_timestamps_per_day: list[int]) -> SafetyCard | None:
    """Reduce prompting for compulsive measurement (PRD §F14.3)."""
    heavy_days = [n for n in weigh_in_timestamps_per_day if n > 2]
    if len(heavy_days) >= 5:
        return SafetyCard(
            trigger="weight_anxiety",
            severity=Severity.INFO,
            title="Weight moves around day to day",
            body=("Daily swings are mostly water, not fat. Weekly is plenty for "
                  "seeing a real trend. We'll ease off the reminders."),
            actions=["Switch to weekly"],
            suppress_ai=False,
        )
    return None
