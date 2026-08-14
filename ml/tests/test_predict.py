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

BASE = dict(
    age_years=44, sex_at_birth="male", height_cm=172.0, weight_kg=82.0,
    waist_cm=102.0, family_history="first_degree", physical_activity="sedentary",
    smoker=False, known_high_bp=False, on_bp_meds=False, history_high_glucose=False,
)


def rec(**kw):
    return {**BASE, **kw}


# ── contract ──────────────────────────────────────────────────────────

def test_contract_loads():
    c = load_contract()
    assert c.version
    assert c.status in ("provisional", "frozen")


def test_leakage_suspects_are_excluded_from_training_by_default():
    """An unaudited feature that silently trains is how a leaky model ships."""
    c = load_contract()
    pending = {f.name for f in c.audit_pending()}
    assert pending == {"known_high_bp", "on_bp_meds", "history_high_glucose"}
    assert not (pending & set(c.model_inputs(tier=1)))


def test_audit_pending_features_are_still_asked_of_the_user():
    """They score in FINDRISC/ADA even while held out of the GBM."""
    c = load_contract()
    asked = {f.name for f in c.asked_of_user(tier=1)}
    assert {"known_high_bp", "on_bp_meds", "history_high_glucose"} <= asked


def test_derived_features_are_present_in_model_inputs():
    cols = load_contract().model_inputs(tier=1)
    assert "bmi" in cols
    assert "waist_to_height_ratio" in cols


def test_lab_values_never_enter_the_tier1_model():
    """Playbook §B7 — do not mean-impute a lab a user never took."""
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


# ── prediction ────────────────────────────────────────────────────────

def test_predict_returns_a_calibrated_probability():
    r = P.predict(rec(), region="bd")
    assert 0.0 <= r.probability <= 1.0


def test_probability_is_never_shown_as_a_bare_point_value():
    """PRD §5 principle 1 — every number carries a range."""
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
    """PRD §7.4b — never let a GBM quietly guess on a population it has not seen."""
    r = P.predict(rec(), region="bd")
    assert r.validation_status == "not_validated"
    assert r.model_version.startswith("clinical_only:")
    assert any("not yet validated" in c for c in r.caveats)


def test_unvalidated_market_reports_a_wider_range():
    r = P.predict(rec(), region="bd")
    assert (r.range_high - r.range_low) > 0.10


def test_disclaimer_is_always_present():
    """PRD §3.2 — risk is never shown without it."""
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
    box = [ln for ln in P.render(r).splitlines() if ln.startswith(("┌", "│", "└"))]
    assert len({len(ln) for ln in box}) == 1, "box drawing rows must be equal width"


# ── the model branch (exercised via a temporary validated pack) ────────

@pytest.fixture
def provisional_pack(tmp_path, monkeypatch):
    """A pack marked 'provisional' so the GBM path runs.

    No shipped pack is validated yet, so without this the model branch would
    never be executed by the suite.
    """
    real_bd = (P.PACKS / "bd.json").read_text(encoding="utf-8")
    pack = json.loads(real_bd)
    pack["code"] = "zt"
    pack["country"] = "Testland"
    pack["risk_model"]["validation_status"] = "provisional"

    target = tmp_path / "zt.json"
    target.write_text(json.dumps(pack), encoding="utf-8")
    # Carry the real packs across too — redirecting the directory otherwise
    # makes every genuine region unreachable inside these tests.
    for src in P.PACKS.glob("*.json"):
        (tmp_path / src.name).write_text(src.read_text(encoding="utf-8"), encoding="utf-8")

    monkeypatch.setattr(P, "PACKS", tmp_path)
    return target


def test_model_path_runs_when_a_market_is_validated(provisional_pack):
    if P.load_model("synthetic") is None:
        pytest.skip("no trained bundle — run ml/pipelines/train.py --synthetic")
    r = P.predict(rec(), region="zt")
    assert r.model_version.startswith("model_a_synthetic@")
    assert 0.0 <= r.probability <= 1.0
    assert not any("not yet validated" in c for c in r.caveats)


def test_validated_market_reports_a_narrower_range(provisional_pack):
    if P.load_model("synthetic") is None:
        pytest.skip("no trained bundle")
    narrow = P.predict(rec(), region="zt")
    wide = P.predict(rec(), region="bd")
    assert (narrow.range_high - narrow.range_low) < (wide.range_high - wide.range_low)
