"""Tests for the Layer-1 clinical scores.

These are published instruments, so the tests assert against the published
point tables — hand-worked cases, boundary values, and the monotonicity that
any risk score must satisfy. If one of these fails, the score is wrong, and a
wrong score would be shown to a user as a health estimate.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pipelines.clinical_scores import (  # noqa: E402
    Subject, ada_risk_test, findrisc, idrs, score_for_region,
)


def make(**kw) -> Subject:
    base = dict(age_years=30, sex_at_birth="male", height_cm=170.0,
                weight_kg=60.0, waist_cm=80.0)
    base.update(kw)
    return Subject(**base)


# ── Subject arithmetic ────────────────────────────────────────────────

def test_bmi():
    assert make(height_cm=170, weight_kg=72.25).bmi == pytest.approx(25.0)


def test_waist_to_height_ratio():
    s = make(height_cm=170, waist_cm=85)
    assert s.waist_to_height_ratio == pytest.approx(0.5)
    assert make(waist_cm=None).waist_to_height_ratio is None


# ── IDRS ──────────────────────────────────────────────────────────────

def test_idrs_minimum():
    """Young, slim, active, no family history → 0/100."""
    r = idrs(make(age_years=30, waist_cm=80, physical_activity="very_active",
                  family_history="none"))
    assert r.points == 0
    assert r.band == "low"


def test_idrs_maximum():
    """Every item at its worst → exactly 100."""
    r = idrs(make(age_years=55, sex_at_birth="male", waist_cm=110,
                  physical_activity="sedentary", family_history="first_degree"))
    assert r.points == 100
    assert r.max_points == 100
    assert r.band == "high"


def test_idrs_female_waist_thresholds():
    """Women use 80/90, men 90/100. The same waist must score differently."""
    assert idrs(make(sex_at_birth="female", waist_cm=85)).points == \
        idrs(make(sex_at_birth="male", waist_cm=95)).points


@pytest.mark.parametrize("waist,expected", [
    (89.9, 0), (90.0, 10), (99.9, 10), (100.0, 20),
])
def test_idrs_male_waist_boundaries(waist, expected):
    got = next(i.points for i in idrs(make(waist_cm=waist)).items if i.key == "waist")
    assert got == expected


@pytest.mark.parametrize("age,expected", [(34, 0), (35, 20), (49, 20), (50, 30)])
def test_idrs_age_boundaries(age, expected):
    got = next(i.points for i in idrs(make(age_years=age)).items if i.key == "age")
    assert got == expected


def test_idrs_missing_waist_is_flagged_not_guessed():
    """A missing waist must lower confidence, never be silently imputed."""
    r = idrs(make(waist_cm=None))
    assert any("Waist missing" in c for c in r.caveats)
    assert next(i for i in r.items if i.key == "waist").points == 0


@pytest.mark.parametrize("subject,points,band", [
    # 0+0+20+0 — some activity only. Below the 30-point low/moderate cut.
    (dict(age_years=30, waist_cm=80, physical_activity="light"), 20, "low"),
    # 20+0+20+0 — crosses into moderate exactly at 30? No: 40.
    (dict(age_years=35, waist_cm=80, physical_activity="light"), 40, "moderate"),
    # 30+10+20+0 = 60, the published high-risk cutoff, inclusive.
    (dict(age_years=50, waist_cm=95, physical_activity="light"), 60, "high"),
])
def test_idrs_band_boundaries(subject, points, band):
    r = idrs(make(family_history="none", **subject))
    assert r.points == points
    assert r.band == band


# ── FINDRISC ──────────────────────────────────────────────────────────

def test_findrisc_minimum():
    r = findrisc(make(age_years=30, height_cm=180, weight_kg=70, waist_cm=85,
                      physical_activity="active", eats_fruit_veg_daily=True))
    assert r.points == 0
    assert r.band == "low"


def test_findrisc_maximum():
    """All eight items maxed → 26, the published maximum."""
    r = findrisc(make(age_years=70, height_cm=170, weight_kg=100, waist_cm=110,
                      sex_at_birth="male", physical_activity="sedentary",
                      eats_fruit_veg_daily=False, on_bp_meds=True,
                      history_high_glucose=True, family_history="first_degree"))
    assert r.points == 26
    assert r.max_points == 26
    assert r.band == "very_high"


def test_findrisc_high_glucose_is_the_heaviest_item():
    """The 5-point history item is why B2 flags it as a leakage suspect."""
    r = findrisc(make(history_high_glucose=True))
    assert next(i.points for i in r.items if i.key == "high_glucose") == 5


def test_findrisc_unknown_diet_does_not_invent_a_penalty():
    r = findrisc(make(eats_fruit_veg_daily=None))
    item = next(i for i in r.items if i.key == "diet")
    assert item.points == 0
    assert "may be 1 point higher" in item.detail


def test_findrisc_warns_about_western_cutoffs():
    assert any("South Asian" in c for c in findrisc(make()).caveats)


# ── ADA ───────────────────────────────────────────────────────────────

def test_ada_minimum_is_zero_for_a_young_active_woman():
    r = ada_risk_test(make(age_years=30, sex_at_birth="female", height_cm=170,
                           weight_kg=60, physical_activity="active"))
    assert r.points == 0
    assert r.band == "low"


def test_ada_maximum():
    r = ada_risk_test(make(age_years=65, sex_at_birth="male", height_cm=170,
                           weight_kg=120, physical_activity="sedentary",
                           family_history="first_degree", known_high_bp=True))
    assert r.points == 3 + 1 + 0 + 1 + 1 + 1 + 3  # BMI 41.5 -> 3
    assert r.points == 10
    assert r.band == "high"


def test_ada_high_risk_cutoff_is_five():
    low = ada_risk_test(make(age_years=45, sex_at_birth="male", height_cm=170,
                             weight_kg=78, physical_activity="active"))
    assert low.points < 5 and low.band == "low"


def test_ada_gestational_only_applies_to_women():
    """A male profile must never score the gestational item."""
    r = ada_risk_test(make(sex_at_birth="male", gestational_diabetes_history=True))
    assert next(i.points for i in r.items if i.key == "gestational") == 0


# ── Cross-cutting invariants ──────────────────────────────────────────

@pytest.mark.parametrize("fn", [idrs, findrisc, ada_risk_test])
def test_points_never_exceed_max(fn):
    worst = make(age_years=90, sex_at_birth="male", height_cm=150, weight_kg=150,
                 waist_cm=150, physical_activity="sedentary",
                 family_history="first_degree", known_high_bp=True,
                 on_bp_meds=True, history_high_glucose=True,
                 eats_fruit_veg_daily=False)
    r = fn(worst)
    assert 0 <= r.points <= r.max_points
    assert 0.0 <= r.fraction <= 1.0


@pytest.mark.parametrize("fn", [idrs, findrisc, ada_risk_test])
def test_worse_inputs_never_lower_the_score(fn):
    """Monotonicity: aging and gaining waist cannot reduce risk."""
    better = make(age_years=30, waist_cm=75, physical_activity="active")
    worse = make(age_years=60, waist_cm=110, physical_activity="sedentary")
    assert fn(worse).points >= fn(better).points


@pytest.mark.parametrize("fn", [idrs, findrisc, ada_risk_test])
def test_every_score_is_explainable(fn):
    """PRD §5 principle 2 — a black-box number is not shippable."""
    r = fn(make(age_years=55, waist_cm=105, family_history="first_degree"))
    assert r.items, "score must expose its per-item breakdown"
    assert r.citation, "score must name its source"
    assert r.interpretation
    assert all(i.label for i in r.items)


@pytest.mark.parametrize("fn", [idrs, findrisc, ada_risk_test])
def test_no_score_claims_a_diagnosis(fn):
    """PRD §2.2 / §3.1 — the app estimates, it never diagnoses.

    Note this bans *claims about the reader*, not the word 'diagnosis'.
    "detects prevalent undiagnosed diabetes" is exactly the honest framing
    Playbook §B1 asks for, so a naive substring ban would punish good copy.
    """
    banned_claims = (
        "you have diabetes", "you are diabetic", "you have type 2",
        "we diagnose", "this diagnoses", "confirms diabetes",
        "cure", "reverse your diabetes", "medically accurate", "clinically proven",
    )
    r = fn(make(age_years=70, waist_cm=120, family_history="first_degree",
                history_high_glucose=True, known_high_bp=True))
    text = (r.interpretation + " " + " ".join(r.caveats)).lower()
    for phrase in banned_claims:
        assert phrase not in text, f"{fn.__name__} copy contains {phrase!r}"


@pytest.mark.parametrize("fn", [idrs, findrisc, ada_risk_test])
def test_highest_band_routes_the_user_to_a_real_test(fn):
    """The product's job is to make the right people go to the lab (Playbook §B0)."""
    r = fn(make(age_years=70, height_cm=170, weight_kg=100, waist_cm=120,
                physical_activity="sedentary", family_history="first_degree",
                history_high_glucose=True, known_high_bp=True, on_bp_meds=True,
                eats_fruit_veg_daily=False))
    assert r.band in ("high", "very_high")
    assert any(w in r.interpretation.lower() for w in ("test", "doctor")), \
        "a high-risk result must point at a blood test or a doctor"


def test_top_factors_are_ranked_and_capped():
    r = idrs(make(age_years=55, waist_cm=110, physical_activity="sedentary",
                  family_history="first_degree"))
    top = r.top_factors(3)
    assert len(top) == 3
    assert [i.points for i in top] == sorted((i.points for i in top), reverse=True)
    assert all(i.points > 0 for i in top)


# ── Region routing ────────────────────────────────────────────────────

@pytest.mark.parametrize("region,expected", [
    ("bd", "IDRS"), ("BD", "IDRS"), ("in", "IDRS"), ("pk", "IDRS"),
    ("us", "ADA"), ("gb", "FINDRISC"), ("eu", "FINDRISC"),
])
def test_region_routing(region, expected):
    assert score_for_region(make(), region).score == expected


def test_unknown_region_falls_back_to_idrs():
    """Launch market is South Asia; an unmapped region should not crash."""
    assert score_for_region(make(), "zz").score == "IDRS"
