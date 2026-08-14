"""Layer-1 clinical risk scores — published, validated, transparent.

These are the defensibility half of the hybrid model (PRD §7.1, Playbook §B8).
The gradient booster supplies accuracy; these supply the sentence we can say to
an Apple reviewer, a doctor, or a regulator:

    "our estimate is anchored to a published, validated instrument, adjusted
     by a model trained on N records, with this calibration curve."

Playbook §B8 is blunt that this sentence is worth more than 0.02 AUC. It is
also the graceful degradation path: in a market where the model has never been
validated, PRD §7.4b requires falling back to a transparent clinical score
rather than quietly guessing.

Every score returns its per-item breakdown, not just a total, because the UI
has to show contributing factors (PRD §5, principle 2) and a black-box number
violates Apple 1.4.1's methodology-disclosure requirement.

No score here is a diagnosis. Each returns a risk *band* with the population
statistic the source paper reported, and nothing more.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal

Sex = Literal["male", "female"]
FamilyHistory = Literal["none", "second_degree", "first_degree"]
Activity = Literal["sedentary", "light", "moderate", "active", "very_active"]


# ──────────────────────────────────────────────────────────────────────
# Inputs & outputs
# ──────────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Subject:
    """One person's answers. Field names match ml/contracts/feature_spec.json."""

    age_years: int
    sex_at_birth: Sex
    height_cm: float
    weight_kg: float
    waist_cm: float | None = None
    family_history: FamilyHistory = "none"
    physical_activity: Activity = "sedentary"
    smoker: bool = False
    known_high_bp: bool = False
    on_bp_meds: bool = False
    history_high_glucose: bool = False
    gestational_diabetes_history: bool | None = None
    eats_fruit_veg_daily: bool | None = None  # FINDRISC only

    @property
    def bmi(self) -> float:
        return self.weight_kg / (self.height_cm / 100.0) ** 2

    @property
    def waist_to_height_ratio(self) -> float | None:
        if self.waist_cm is None:
            return None
        return self.waist_cm / self.height_cm


@dataclass
class Item:
    """One scored question, kept so the UI can explain the total."""

    key: str
    label: str
    points: int
    detail: str = ""


@dataclass
class ScoreResult:
    score: str
    points: int
    max_points: int
    band: str
    interpretation: str
    items: list[Item] = field(default_factory=list)
    citation: str = ""
    caveats: list[str] = field(default_factory=list)

    @property
    def fraction(self) -> float:
        return self.points / self.max_points if self.max_points else 0.0

    def top_factors(self, n: int = 3) -> list[Item]:
        """Highest-scoring items, for the factor-breakdown screen."""
        return sorted((i for i in self.items if i.points > 0),
                      key=lambda i: i.points, reverse=True)[:n]


# ──────────────────────────────────────────────────────────────────────
# IDRS — Indian Diabetes Risk Score (MDRF)
# ──────────────────────────────────────────────────────────────────────

def idrs(s: Subject) -> ScoreResult:
    """Indian Diabetes Risk Score — the Layer-1 score for South Asia.

    Four items, max 100. Validated in Indian populations, and its waist
    thresholds (90 cm men / 80 cm women) are already South-Asian-appropriate
    rather than needing the Western-cutoff correction of Playbook §B9. That,
    plus its brevity, is why it is the right anchor for the Bangladesh launch.

    Reference: Mohan V, et al. "A simplified Indian Diabetes Risk Score for
    screening for undiagnosed diabetic subjects." J Assoc Physicians India,
    2005;53:759-63.
    """
    items: list[Item] = []

    if s.age_years < 35:
        items.append(Item("age", "Age under 35", 0))
    elif s.age_years < 50:
        items.append(Item("age", "Age 35–49", 20))
    else:
        items.append(Item("age", "Age 50 or over", 30))

    if s.waist_cm is None:
        items.append(Item("waist", "Waist not provided", 0,
                          "Waist is an IDRS input; the score is incomplete without it."))
    else:
        low, high = (90.0, 100.0) if s.sex_at_birth == "male" else (80.0, 90.0)
        if s.waist_cm < low:
            items.append(Item("waist", f"Waist {s.waist_cm:.0f} cm", 0))
        elif s.waist_cm < high:
            items.append(Item("waist", f"Waist {s.waist_cm:.0f} cm", 10, "Above the South Asian threshold"))
        else:
            items.append(Item("waist", f"Waist {s.waist_cm:.0f} cm", 20, "Well above the South Asian threshold"))

    if s.physical_activity in ("active", "very_active"):
        items.append(Item("activity", "Regular vigorous activity", 0))
    elif s.physical_activity in ("light", "moderate"):
        items.append(Item("activity", "Some activity", 20))
    else:
        items.append(Item("activity", "Sedentary", 30))

    if s.family_history == "first_degree":
        items.append(Item("family", "Parent or sibling with diabetes", 20))
    elif s.family_history == "second_degree":
        items.append(Item("family", "More distant family history", 10))
    else:
        items.append(Item("family", "No family history", 0))

    total = sum(i.points for i in items)
    if total < 30:
        band, interp = "low", "Low risk of undiagnosed diabetes."
    elif total < 60:
        band, interp = "moderate", "Moderate risk. A fasting glucose test is worthwhile."
    else:
        band, interp = "high", "High risk. A fasting glucose or HbA1c test is strongly advised."

    return ScoreResult(
        score="IDRS", points=total, max_points=100, band=band, interpretation=interp,
        items=items,
        citation="Mohan V, et al. J Assoc Physicians India 2005;53:759-63.",
        caveats=[
            "Validated in Indian populations; Bangladeshi validation is by cultural "
            "and anthropometric proximity, not by direct study.",
            "Detects PREVALENT undiagnosed diabetes, not future incidence.",
        ] + ([] if s.waist_cm is not None else ["Waist missing — score is not comparable to a complete one."]),
    )


# ──────────────────────────────────────────────────────────────────────
# FINDRISC — Finnish Diabetes Risk Score
# ──────────────────────────────────────────────────────────────────────

def findrisc(s: Subject) -> ScoreResult:
    """FINDRISC — the Layer-1 score for European markets. Max 26.

    Unlike IDRS, this one reports a 10-year INCIDENCE estimate, which is a
    different question from the screening task the ML model is trained for
    (Playbook §B1). Do not present the two as interchangeable numbers.

    Reference: Lindström J, Tuomilehto J. "The diabetes risk score: a practical
    tool to predict type 2 diabetes risk." Diabetes Care 2003;26(3):725-31.
    """
    items: list[Item] = []

    if s.age_years < 45:
        items.append(Item("age", "Age under 45", 0))
    elif s.age_years < 55:
        items.append(Item("age", "Age 45–54", 2))
    elif s.age_years <= 64:
        items.append(Item("age", "Age 55–64", 3))
    else:
        items.append(Item("age", "Age over 64", 4))

    bmi = s.bmi
    if bmi < 25:
        items.append(Item("bmi", f"BMI {bmi:.1f}", 0))
    elif bmi <= 30:
        items.append(Item("bmi", f"BMI {bmi:.1f}", 1))
    else:
        items.append(Item("bmi", f"BMI {bmi:.1f}", 3))

    if s.waist_cm is None:
        items.append(Item("waist", "Waist not provided", 0))
    else:
        low, high = (94.0, 102.0) if s.sex_at_birth == "male" else (80.0, 88.0)
        pts = 0 if s.waist_cm < low else (3 if s.waist_cm < high else 4)
        items.append(Item("waist", f"Waist {s.waist_cm:.0f} cm", pts))

    active = s.physical_activity in ("moderate", "active", "very_active")
    items.append(Item("activity", "At least 30 min activity daily" if active
                      else "Under 30 min activity daily", 0 if active else 2))

    if s.eats_fruit_veg_daily is None:
        items.append(Item("diet", "Fruit/vegetable intake not asked", 0,
                          "Assumed favourable; the true score may be 1 point higher."))
    else:
        items.append(Item("diet", "Eats fruit/vegetables daily" if s.eats_fruit_veg_daily
                          else "Does not eat fruit/vegetables daily",
                          0 if s.eats_fruit_veg_daily else 1))

    items.append(Item("bp_meds", "Takes blood pressure medication" if s.on_bp_meds
                      else "No blood pressure medication", 2 if s.on_bp_meds else 0))

    items.append(Item("high_glucose", "Previously told of high blood glucose"
                      if s.history_high_glucose else "No history of high blood glucose",
                      5 if s.history_high_glucose else 0))

    fam_pts = {"none": 0, "second_degree": 3, "first_degree": 5}[s.family_history]
    items.append(Item("family", {"none": "No family history",
                                 "second_degree": "More distant family history",
                                 "first_degree": "Parent, sibling or child with diabetes"}[s.family_history],
                      fam_pts))

    # Every band above "low" ends in an action, not a bare statistic. PRD §3.1
    # requires a doctor-referral CTA on any risk result, and Playbook §B0 is
    # explicit that the product's job is to route the right people to a lab.
    total = sum(i.points for i in items)
    if total < 7:
        band = "low"
        interp = ("Estimated 1 in 100 will develop type 2 diabetes within 10 years. "
                  "Keep up your current habits.")
    elif total < 12:
        band = "slightly_elevated"
        interp = ("Estimated 1 in 25 within 10 years. Worth mentioning to a doctor "
                  "at your next visit.")
    elif total < 15:
        band = "moderate"
        interp = ("Estimated 1 in 6 within 10 years. Consider asking a doctor for a "
                  "fasting glucose test.")
    elif total <= 20:
        band = "high"
        interp = ("Estimated 1 in 3 within 10 years. Talk to a doctor about a fasting "
                  "glucose or HbA1c test.")
    else:
        band = "very_high"
        interp = ("Estimated 1 in 2 within 10 years. Talk to a doctor about a fasting "
                  "glucose or HbA1c test soon.")

    return ScoreResult(
        score="FINDRISC", points=total, max_points=26, band=band, interpretation=interp,
        items=items,
        citation="Lindström J, Tuomilehto J. Diabetes Care 2003;26(3):725-31.",
        caveats=[
            "Derived in a Finnish cohort. Its BMI and waist cutoffs are Western and "
            "under-detect South Asians — use IDRS for South Asian markets (Playbook §B9).",
            "Reports 10-year INCIDENCE, a different question from the screening model. "
            "Never blend the two numbers without saying which is which.",
        ],
    )


# ──────────────────────────────────────────────────────────────────────
# ADA Diabetes Risk Test
# ──────────────────────────────────────────────────────────────────────

def ada_risk_test(s: Subject) -> ScoreResult:
    """ADA Diabetes Risk Test — the Layer-1 score for the US market. Max 11.

    Reference: American Diabetes Association, Diabetes Risk Test; derived from
    Bang H, et al. Ann Intern Med 2009;151(11):775-83.
    """
    items: list[Item] = []

    if s.age_years < 40:
        items.append(Item("age", "Age under 40", 0))
    elif s.age_years < 50:
        items.append(Item("age", "Age 40–49", 1))
    elif s.age_years < 60:
        items.append(Item("age", "Age 50–59", 2))
    else:
        items.append(Item("age", "Age 60 or over", 3))

    male = s.sex_at_birth == "male"
    items.append(Item("sex", "Male" if male else "Female", 1 if male else 0))

    if s.sex_at_birth == "female" and s.gestational_diabetes_history:
        items.append(Item("gestational", "History of gestational diabetes", 1))
    else:
        items.append(Item("gestational", "No gestational diabetes history", 0))

    first_degree = s.family_history == "first_degree"
    items.append(Item("family", "Parent or sibling with diabetes" if first_degree
                      else "No parent or sibling with diabetes", 1 if first_degree else 0))

    items.append(Item("bp", "Diagnosed with high blood pressure" if s.known_high_bp
                      else "No high blood pressure", 1 if s.known_high_bp else 0))

    active = s.physical_activity in ("moderate", "active", "very_active")
    items.append(Item("activity", "Physically active" if active else "Not physically active",
                      0 if active else 1))

    bmi = s.bmi
    if bmi < 25:
        pts = 0
    elif bmi < 30:
        pts = 1
    elif bmi < 40:
        pts = 2
    else:
        pts = 3
    items.append(Item("bmi", f"BMI {bmi:.1f}", pts))

    total = sum(i.points for i in items)
    if total >= 5:
        band = "high"
        interp = "At increased risk. The ADA advises talking to a doctor about a blood glucose test."
    else:
        band = "low"
        interp = "Lower risk on this instrument. Re-check if weight, activity or age changes."

    return ScoreResult(
        score="ADA", points=total, max_points=11, band=band, interpretation=interp,
        items=items,
        citation="American Diabetes Association Diabetes Risk Test; Bang H, et al. "
                 "Ann Intern Med 2009;151(11):775-83.",
        caveats=[
            "Western BMI cutoffs — under-detects South Asians.",
            "A binary high/low cut at 5 points; it is a triage tool, not a probability.",
        ],
    )


# ──────────────────────────────────────────────────────────────────────
# Region routing
# ──────────────────────────────────────────────────────────────────────

SCORES = {"idrs": idrs, "findrisc": findrisc, "ada": ada_risk_test}

# Which published instrument anchors which market.
#
# packs/*.json is the SOURCE OF TRUTH — the backend reads clinical_score from
# the region pack. This table exists so the ML side can evaluate the same
# routing offline, and ml/scripts/validate_packs.py asserts the two agree. A
# disagreement means the model and the app anchor a market to different
# instruments, which is why that check is an error rather than a warning.
#
# Assignments are by derivation population, not by convenience:
#   idrs     — South Asian populations, where it was derived and validated,
#              and whose waist thresholds are already correct for them.
#   ada      — US/Canada, where it is the familiar public instrument.
#   findrisc — European-derived; used for Europe, and for Anglophone and Gulf
#              markets as the least-bad published option.
DEFAULT_SCORE_BY_REGION = {
    # South Asia — IDRS is derived and validated here.
    "bd": "idrs", "in": "idrs", "pk": "idrs", "np": "idrs", "lk": "idrs",
    "bt": "idrs", "mv": "idrs",
    # North America.
    "us": "ada", "ca": "ada",
    # Europe — FINDRISC's home ground.
    "gb": "findrisc", "ie": "findrisc", "de": "findrisc", "fr": "findrisc",
    "it": "findrisc", "es": "findrisc", "nl": "findrisc", "be": "findrisc",
    "at": "findrisc", "pt": "findrisc", "pl": "findrisc", "se": "findrisc",
    "dk": "findrisc", "fi": "findrisc", "no": "findrisc", "ch": "findrisc",
    "eu": "findrisc",
    # Oceania.
    "au": "findrisc", "nz": "findrisc",
    # Gulf / MENA. See the caveat on UNVALIDATED_SCORE_REGIONS below.
    "ae": "findrisc", "sa": "findrisc", "qa": "findrisc", "kw": "findrisc",
    "om": "findrisc", "bh": "findrisc", "eg": "findrisc",
    # Southeast Asia.
    "my": "findrisc", "id": "findrisc", "sg": "findrisc", "ph": "findrisc",
    "th": "findrisc", "vn": "findrisc",
}

# Markets where the assigned score was NOT derived in that population. The
# assignment is a least-bad default, not a validated choice, and any result
# carries an explicit caveat saying so. PRD §7.4b: be honest in the UI about
# validation status rather than quietly guessing — users and regulators both
# reward it.
UNVALIDATED_SCORE_REGIONS = {
    "ae", "sa", "qa", "kw", "om", "bh", "eg",
    "my", "id", "sg", "ph", "th", "vn",
    "au", "nz",
}

FALLBACK_SCORE = "findrisc"

# Cambridge Risk Score is deliberately NOT implemented. It is a logistic model
# with published coefficients rather than a point table, and implementing it
# from memory risks shipping wrong numbers into a health product. Add it only
# from the source paper, with a test against the worked examples in that paper.


def score_for_region(s: Subject, region: str, score: str | None = None) -> ScoreResult:
    """Run the clinical score anchoring this market.

    `score` comes from the region pack and wins when supplied; the table is the
    offline fallback. An unmapped region does not silently inherit a South Asian
    instrument — it gets the documented fallback plus a caveat on the result.
    """
    code = region.lower()
    chosen = score or DEFAULT_SCORE_BY_REGION.get(code)

    unmapped = chosen is None
    if unmapped:
        chosen = FALLBACK_SCORE

    if chosen not in SCORES:
        raise ValueError(f"unknown clinical score {chosen!r}; expected one of {sorted(SCORES)}")

    result = SCORES[chosen](s)

    if unmapped:
        result.caveats.insert(0, (
            f"No clinical score is configured for region {region!r}; falling back to "
            f"{result.score}. Treat this as unvalidated for this population."
        ))
    elif code in UNVALIDATED_SCORE_REGIONS:
        result.caveats.insert(0, (
            f"{result.score} was not derived in this population. It is the best "
            f"available published instrument for {region.upper()}, not a validated one."
        ))
    return result
