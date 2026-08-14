"""Tests for the contract and the inference path.

The behaviours asserted here are product requirements, not implementation
detail: a percentage that is never a bare point value, an honest degradation
when a market is unvalidated, and a factor breakdown that separates what the
user can change from what they cannot.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from pipelines import predict as P  # noqa: E402
from pipelines.contract import add_derived, load_contract  # noqa: E402

LEAKAGE_SUSPECTS = {"known_high_bp", "on_bp_meds", "history_high_glucose"}

BASE = dict(
    age_years=44, sex_at_birth="male", height_cm=172.0, weight_kg=82.0,
    waist_cm=102.0, family_history="first_degree", physical_activity="sedentary",
    smoker=False, known_high_bp=False, on_bp_meds=False, history_high_glucose=False,
)


def rec(**kw):
    return {**BASE, **kw}


# -- contract ---------------------------------------------------------

def test_contract_is_frozen():
    c = load_contract()
    assert c.status == "frozen"
    assert c.version.startswith("1.")
    assert not c.audit_pending(), "nothing may remain unruled once frozen"


def test_leakage_suspects_never_reach_the_model():
    """The audit ruled all three out of the GBM. See docs/leakage_audit.md."""
    c = load_contract()
    assert {f.name for f in c.clinical_score_only()} == LEAKAGE_SUSPECTS
    assert not (LEAKAGE_SUSPECTS & set(c.model_inputs(tier=1)))


def test_leakage_suspects_are_still_asked_of_the_user():
    """They remain legitimate, published FINDRISC/ADA inputs."""
    asked = {f.name for f in load_contract().asked_of_user(tier=1)}
    assert LEAKAGE_SUSPECTS <= asked


def test_derived_features_are_present_in_model_inputs():
    cols = load_contract().model_inputs(tier=1)
    assert "bmi" in cols
    assert "waist_to_height_ratio" in cols


def test_lab_values_never_enter_the_tier1_model():
    """Playbook B7 - do not mean-impute a lab a user never took."""
    cols = load_contract().model_inputs(tier=1)
    for lab in ("fasting_glucose_mmol_l", "hba1c_percent", "hdl_mmol_l"):
        assert lab not in cols


def test_add_derived_matches_the_documented_formula():
    out = add_derived(rec(height_cm=170.0, weight_kg=72.25, waist_cm=85.0))
    assert out["bmi"] == pytest.approx(25.0)
    assert out["waist_to_height_ratio"] == pytest.approx(0.5)


def test_add_derived_does_not_mutate_its_input():
    original = rec()
    add_derived(original)
    assert "bmi" not in original


def test_add_derived_handles_missing_waist():
    """BRFSS has no waist column; missing must stay missing, not become 0."""
    out = add_derived(rec(waist_cm=None))
    assert out["waist_to_height_ratio"] is None


@pytest.mark.parametrize("bad,msg", [
    (dict(age_years=None), "required"),
    (dict(age_years=9), "outside"),
    (dict(sex_at_birth="other"), "not in"),
    (dict(family_history="cousin"), "not in"),
    (dict(weight_kg=500.0), "outside"),
])
def test_validation_rejects_bad_records(bad, msg):
    problems = load_contract().validate(rec(**bad), tier=1)
    assert any(msg in p for p in problems), problems


# -- prediction -------------------------------------------------------

def test_predict_returns_a_calibrated_probability():
    r = P.predict(rec(), region="bd")
    assert 0.0 <= r.probability <= 1.0


def test_probability_is_never_shown_as_a_bare_point_value():
    """PRD 5, principle 1 - every number carries a range."""
    r = P.predict(rec(), region="bd")
    assert r.range_low < r.probability < r.range_high


def test_high_risk_person_scores_above_low_risk_person():
    high = P.predict(rec(), region="bd")
    low = P.predict(rec(age_years=25, weight_kg=55.0, waist_cm=72.0,
                        family_history="none", physical_activity="very_active"),
                    region="bd")
    assert high.probability > low.probability
    assert high.clinical_points > low.clinical_points


def test_factors_split_modifiable_from_fixed():
    """Age and family history go in their own section so users are not demoralised."""
    r = P.predict(rec(), region="bd")
    fixed = {f.label for f in r.fixed_factors}
    modifiable = {f.label for f in r.modifiable_factors}
    assert any("Age" in f for f in fixed)
    assert any("diabetes" in f for f in fixed)          # family history
    assert any("Sedentary" in f for f in modifiable)
    assert not (fixed & modifiable)


def test_unvalidated_market_degrades_to_the_clinical_score_and_says_so():
    """PRD 7.4b - never let a GBM quietly guess on a population it has not seen."""
    r = P.predict(rec(), region="bd")
    assert r.validation_status == "not_validated"
    assert r.model_version.startswith("clinical_only:")
    assert any("not yet validated" in c for c in r.caveats)


def test_unvalidated_market_reports_a_wider_range():
    r = P.predict(rec(), region="bd")
    assert (r.range_high - r.range_low) > 0.10


def test_provisional_market_runs_the_model():
    """The US pack is trained and tested on NHANES, so it earns the GBM path."""
    if P.load_model("v1") is None:
        pytest.skip("no trained bundle - run python -m ml.pipelines.train")
    r = P.predict(rec(), region="us")
    assert r.validation_status == "provisional"
    assert r.model_version.startswith("model_a_v1@")
    assert not any("not yet validated" in c for c in r.caveats)


def test_disclaimer_is_always_present():
    """PRD 3.2 - risk is never shown without it."""
    r = P.predict(rec(), region="bd")
    assert "not a diagnosis" in r.disclaimer


def test_result_never_claims_a_diagnosis():
    r = P.predict(rec(), region="bd")
    text = " ".join([r.basis, r.disclaimer, *r.caveats]).lower()
    for phrase in ("you have diabetes", "you are diabetic", "confirms diabetes", "cure"):
        assert phrase not in text


def test_invalid_record_is_rejected_before_scoring():
    with pytest.raises(ValueError, match="Invalid record"):
        P.predict(rec(age_years=12), region="bd")


def test_unknown_region_is_rejected_clearly():
    with pytest.raises(FileNotFoundError, match="No region pack"):
        P.predict(rec(), region="zz")


@pytest.mark.parametrize("region", ["bd", "in", "us", "gb", "de", "ae"])
def test_predict_works_for_every_shipped_pack(region):
    r = P.predict(rec(), region=region)
    assert 0.0 <= r.probability <= 1.0
    assert r.region == region
    assert r.clinical_score in ("IDRS", "FINDRISC", "ADA")


def test_region_changes_which_instrument_answers():
    assert P.predict(rec(), region="bd").clinical_score == "IDRS"
    assert P.predict(rec(), region="us").clinical_score == "ADA"
    assert P.predict(rec(), region="de").clinical_score == "FINDRISC"


def test_band_matches_probability():
    for lo, hi, key, _ in P.BANDS:
        mid = (lo + min(hi, 1.0)) / 2
        assert P._band(mid)[0] == key


def test_render_produces_aligned_output():
    r = P.predict(rec(), region="bd")
    box = [ln for ln in P.render(r).splitlines()
           if ln[:1] in {"┌", "│", "└"}]
    assert box, "render must draw the result box"
    assert len({len(ln) for ln in box}) == 1, "box drawing rows must be equal width"


# -- Tier 2: lab interpretation ---------------------------------------

def test_no_labs_stays_tier_1():
    r = P.predict(rec(), region="bd")
    assert r.tier == 1
    assert r.lab_findings == []
    assert r.lab_statement is None


@pytest.mark.parametrize("hba1c,band", [
    (5.2, "normal"), (5.6, "normal"),
    (5.7, "prediabetes"), (6.4, "prediabetes"),
    (6.5, "diabetes_range"), (9.0, "diabetes_range"),
])
def test_hba1c_bands_follow_published_thresholds(hba1c, band):
    """ADA Standards of Care: <5.7 normal, 5.7-6.4 prediabetes, >=6.5 diabetes."""
    r = P.predict(rec(hba1c_percent=hba1c), region="bd")
    assert r.tier == 2
    assert r.lab_findings[0].band == band


@pytest.mark.parametrize("fpg,band", [
    (5.0, "normal"), (5.6, "prediabetes"), (6.9, "prediabetes"), (7.0, "diabetes_range"),
])
def test_fasting_glucose_bands(fpg, band):
    r = P.predict(rec(fasting_glucose_mmol_l=fpg), region="bd")
    assert r.lab_findings[0].band == band


def test_hba1c_outranks_fasting_glucose():
    """HbA1c is the three-month average and covers far more people."""
    r = P.predict(rec(hba1c_percent=6.1, fasting_glucose_mmol_l=5.2), region="bd")
    assert r.lab_findings[0].test == "HbA1c"
    assert "hba1c" in r.basis.lower()


def test_a_normal_lab_lowers_the_estimate_below_the_questionnaire():
    """A measurement beats an estimate, even a pessimistic one."""
    without = P.predict(rec(), region="bd")
    with_normal = P.predict(rec(hba1c_percent=5.1), region="bd")
    assert with_normal.probability < without.probability
    assert with_normal.band == "low"


def test_a_diabetes_range_lab_dominates_the_estimate():
    r = P.predict(rec(hba1c_percent=8.0), region="bd")
    assert r.probability >= 0.90
    assert r.band == "very_high"


def test_labs_narrow_the_range():
    """A measured value carries less uncertainty than a questionnaire."""
    without = P.predict(rec(), region="bd")
    with_lab = P.predict(rec(hba1c_percent=6.1), region="bd")
    assert (with_lab.range_high - with_lab.range_low) < (without.range_high - without.range_low)


def test_a_diabetes_range_lab_still_does_not_diagnose():
    """PRD §2.2 — a single value is not a diagnosis; a repeat test is needed."""
    r = P.predict(rec(hba1c_percent=9.5), region="bd")
    text = (r.lab_statement or "").lower()
    assert "repeat test" in text
    assert "you have diabetes" not in text
    assert "not a diagnosis" in r.disclaimer


def test_the_result_says_the_estimate_came_from_a_lab_not_the_model():
    r = P.predict(rec(hba1c_percent=6.1), region="bd")
    assert any("lab value you entered" in c for c in r.caveats)


def test_modifiable_factors_survive_tier_2():
    """Even with a bad lab result, the user needs something they can act on."""
    r = P.predict(rec(hba1c_percent=8.0), region="bd")
    assert r.modifiable_factors


def test_labs_are_never_model_features():
    """Feeding HbA1c to the GBM lifts AUC 0.808 -> 0.939 purely by leakage:
    the training label is defined as HbA1c >= 6.5."""
    cols = load_contract().model_inputs(tier=1)
    assert "hba1c_percent" not in cols
    assert "fasting_glucose_mmol_l" not in cols


# -- the model branch, via a temporary provisional pack ----------------

@pytest.fixture
def provisional_pack(tmp_path, monkeypatch):
    """A copy of the BD pack marked 'provisional', so the GBM path runs on it."""
    pack = json.loads((P.PACKS / "bd.json").read_text(encoding="utf-8"))
    pack["code"] = "zt"
    pack["country"] = "Testland"
    pack["risk_model"]["validation_status"] = "provisional"

    # Carry the real packs across too - redirecting the directory otherwise
    # makes every genuine region unreachable inside these tests.
    for src in P.PACKS.glob("*.json"):
        (tmp_path / src.name).write_text(src.read_text(encoding="utf-8"), encoding="utf-8")
    (tmp_path / "zt.json").write_text(json.dumps(pack), encoding="utf-8")

    monkeypatch.setattr(P, "PACKS", tmp_path)
    return tmp_path / "zt.json"


def test_model_path_runs_when_a_market_is_validated(provisional_pack):
    if P.load_model("v1") is None:
        pytest.skip("no trained bundle")
    r = P.predict(rec(), region="zt")
    assert r.model_version.startswith("model_a_v1@")
    assert 0.0 <= r.probability <= 1.0
    assert not any("not yet validated" in c for c in r.caveats)


def test_validated_market_reports_a_narrower_range(provisional_pack):
    if P.load_model("v1") is None:
        pytest.skip("no trained bundle")
    narrow = P.predict(rec(), region="zt")
    wide = P.predict(rec(), region="bd")
    assert (narrow.range_high - narrow.range_low) < (wide.range_high - wide.range_low)
