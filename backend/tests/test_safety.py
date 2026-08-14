"""Adversarial tests for the safety rails. PRD §18 requires these before release.

PRD §14 sets the red-flag false-negative rate on the golden set at ZERO. These
tests are that golden set. A false positive here is an unnecessary "see a
doctor" card; a false negative is a missed emergency. They are not comparable,
and these tests are written accordingly.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.safety import (  # noqa: E402
    ABSOLUTE, Severity, check_disordered_eating, check_glucose, check_profile,
    check_text, check_weight_anxiety, clamp_calorie_target,
)


# ── glucose ───────────────────────────────────────────────────────────

@pytest.mark.parametrize("value", [3.8, 3.0, 2.2, 1.0])
def test_hypoglycaemia_is_caught(value):
    card = check_glucose(value)
    assert card is not None
    assert card.trigger == "hypoglycaemia"
    assert card.severity is Severity.URGENT
    assert "15g" in card.body or "15 g" in card.body


@pytest.mark.parametrize("value", [14.0, 20.0, 33.0])
def test_high_fasting_glucose_is_caught(value):
    card = check_glucose(value, context="fasting")
    assert card is not None and card.trigger == "hyperglycaemia"


def test_random_glucose_uses_the_higher_threshold():
    """14.0 is urgent when fasting, but within range for a random reading."""
    assert check_glucose(14.0, context="fasting") is not None
    assert check_glucose(14.0, context="random") is None
    assert check_glucose(17.0, context="random") is not None


@pytest.mark.parametrize("value", [4.0, 5.5, 7.0, 10.0])
def test_normal_glucose_passes(value):
    assert check_glucose(value, context="random") is None


def test_boundary_values_are_not_flagged():
    """Exactly at the threshold is not over it."""
    assert check_glucose(ABSOLUTE["hypoglycaemia"]) is None
    assert check_glucose(ABSOLUTE["fasting_urgent"], context="fasting") is None


def test_a_region_pack_may_tighten_but_never_loosen():
    """PRD §3.3 thresholds are a ceiling, not a suggestion."""
    # Tightening works: 12.0 is now urgent when fasting.
    assert check_glucose(12.5, "fasting", {"fasting_urgent": 12.0}) is not None
    # Loosening is ignored: 14.0 is still urgent despite the pack asking for 20.
    assert check_glucose(14.0, "fasting", {"fasting_urgent": 20.0}) is not None
    # And a pack raising the hypo floor still catches a low reading.
    assert check_glucose(4.2, thresholds={"hypoglycaemia": 4.5}) is not None


def test_hyperglycaemia_card_never_suggests_a_dose_change():
    """Apple 1.4.2 — no dosing logic anywhere in the product."""
    card = check_glucose(25.0, context="random")
    assert "do not change any medication" in card.body.lower()


# ── free text ─────────────────────────────────────────────────────────

@pytest.mark.parametrize("message", [
    "I have chest pain and my arm hurts",
    "my father passed out this morning",
    "her breath smells sweet and she is vomiting and can't keep fluids down",
    "there is a foot ulcer that wound won't heal",
    "sudden vision loss in my left eye",
    "I feel confused and my speech is slurred",
])
def test_emergency_phrases_are_caught(message):
    card = check_text(message)
    assert card is not None, f"MISSED EMERGENCY: {message!r}"
    assert card.severity is Severity.EMERGENCY
    assert card.blocks_response
    assert card.suppress_ai


@pytest.mark.parametrize("message", [
    "I want to kill myself",
    "there is no reason to live anymore",
    "I have been thinking about suicide",
])
def test_crisis_phrases_are_caught(message):
    card = check_text(message)
    assert card is not None and card.trigger == "self_harm"
    assert card.suppress_ai


def test_crisis_outranks_a_simultaneous_medical_flag():
    """Both present — the crisis response must win."""
    card = check_text("I have chest pain and I want to kill myself")
    assert card.trigger == "self_harm"


def test_crisis_card_is_supportive_not_clinical():
    card = check_text("I want to die")
    assert "not alone" in card.title.lower() or "don't have to" in card.title.lower()


@pytest.mark.parametrize("message", [
    "can I eat mango?",
    "why is my morning sugar high?",
    "I walked 5000 steps today",
    "",
])
def test_ordinary_messages_pass_through(message):
    assert check_text(message) is None


def test_detection_survives_casing_and_spacing():
    assert check_text("  CHEST   PAIN  ") is not None
    assert check_text("ChEsT pAiN") is not None


def test_bangla_emergency_phrases_are_caught():
    """PRD §F10 — the coach answers in Bangla, so it must screen Bangla."""
    assert check_text("আমার বুকে ব্যথা হচ্ছে") is not None


# ── profile gates ─────────────────────────────────────────────────────

@pytest.mark.parametrize("age", [17, 12, 5])
def test_under_18_is_blocked(age):
    card = check_profile(age=age)
    assert card is not None and card.trigger == "under_18"


def test_18_is_allowed():
    assert check_profile(age=18) is None


def test_pregnancy_switches_to_doctor_mode():
    card = check_profile(age=30, pregnant=True)
    assert card is not None and card.trigger == "pregnancy"
    assert not card.suppress_ai        # tracking continues, targets do not


@pytest.mark.parametrize("condition", ["CKD", "chronic kidney disease", "Heart Failure"])
def test_blocking_conditions_disable_auto_diet_plans(condition):
    card = check_profile(age=50, conditions=[condition])
    assert card is not None and card.trigger.startswith("condition:")


# ── calorie rails ─────────────────────────────────────────────────────

def test_female_floor_is_1200():
    """TDEE 1600 leaves the deficit cap at 1100, so the absolute floor binds."""
    t = clamp_calorie_target(requested_kcal=900, sex="female", tdee=1600)
    assert t.kcal == 1200 and t.was_clamped
    assert "absolute floor" in t.reason


def test_male_floor_is_1500():
    t = clamp_calorie_target(requested_kcal=1000, sex="male", tdee=1900)
    assert t.kcal == 1500 and t.was_clamped
    assert "absolute floor" in t.reason


def test_deficit_is_capped_at_500():
    t = clamp_calorie_target(requested_kcal=1000, sex="male", tdee=3000)
    assert t.kcal == 2500
    assert "deficit capped" in t.reason


def test_whichever_constraint_is_stricter_wins():
    """Both rails apply; the safer number is the one that survives.

    At TDEE 2000 the deficit cap (1500) is stricter than the female floor
    (1200), so 1500 is correct — clamping to 1200 there would permit a
    700 kcal deficit.
    """
    t = clamp_calorie_target(requested_kcal=900, sex="female", tdee=2000)
    assert t.kcal == 1500
    assert t.kcal >= ABSOLUTE["min_kcal_female"]
    assert t.kcal >= 2000 - ABSOLUTE["max_deficit_kcal"]


def test_a_reasonable_target_is_left_alone():
    t = clamp_calorie_target(requested_kcal=1800, sex="female", tdee=2100)
    assert t.kcal == 1800 and not t.was_clamped and t.reason is None


def test_low_bmi_disables_weight_loss_entirely():
    t = clamp_calorie_target(requested_kcal=1400, sex="female", tdee=1900, bmi=17.2)
    assert t.weight_loss_disabled
    assert t.kcal == 1900                       # maintenance, not a deficit


@pytest.mark.parametrize("requested", [0, -500, 1, 200])
def test_absurd_requests_still_land_on_the_floor(requested):
    """A wrong number typed once must not be able to starve anyone (PRD §3.6)."""
    t = clamp_calorie_target(requested_kcal=requested, sex="female", tdee=2000)
    assert t.kcal >= ABSOLUTE["min_kcal_female"]


def test_floors_hold_even_when_tdee_is_implausibly_low():
    """A very low TDEE must not drag the floor down with it."""
    t = clamp_calorie_target(requested_kcal=800, sex="male", tdee=1200)
    assert t.kcal >= ABSOLUTE["min_kcal_male"]


# ── eating-disorder and anxiety guards ────────────────────────────────

def test_repeated_very_low_intake_is_flagged():
    card = check_disordered_eating([700, 650, 720, 1800])
    assert card is not None and card.trigger.startswith("disordered_eating")


def test_one_low_day_is_not_flagged():
    """People skip meals. Two low days is not a disorder."""
    assert check_disordered_eating([700, 2000, 1900]) is None


def test_unrealistic_goal_weight_is_flagged():
    card = check_disordered_eating([2000, 2000], goal_bmi=16.5)
    assert card is not None and card.trigger.endswith("goal_bmi")


def test_guard_language_is_supportive_never_shaming():
    card = check_disordered_eating([700, 650, 700])
    text = (card.title + " " + card.body).lower()
    for word in ("fail", "failed", "bad", "wrong", "should have", "lazy"):
        assert word not in text


def test_frequent_weighing_reduces_prompting():
    card = check_weight_anxiety([3, 4, 3, 5, 3])
    assert card is not None and card.trigger == "weight_anxiety"
    assert card.severity is Severity.INFO


def test_normal_weighing_is_left_alone():
    assert check_weight_anxiety([1, 1, 0, 1, 2, 1]) is None
