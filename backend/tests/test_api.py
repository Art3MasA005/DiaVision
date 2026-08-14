"""End-to-end API tests against a real database.

Covers the vertical slice: signup -> health profile -> risk assessment, plus
the safety and authorisation behaviour that must hold on every path.
"""

from __future__ import annotations

import sys
import uuid
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.db.session import engine  # noqa: E402
from app.main import app  # noqa: E402

API = "/api/v1"


def _database_available() -> bool:
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return True
    except Exception:
        return False


pytestmark = pytest.mark.skipif(not _database_available(), reason="no database")


@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c


def _signup(client, **overrides) -> dict:
    body = {
        "email": f"u{uuid.uuid4().hex[:12]}@example.com",
        "password": "correct horse battery staple",
        "display_name": "Test User",
        "region": "bd",
        "locale": "bn",
        "accept_disclaimer": True,
    }
    body.update(overrides)
    resp = client.post(f"{API}/auth/signup", json=body)
    assert resp.status_code == 201, resp.text
    return {"tokens": resp.json(), "email": body["email"], "password": body["password"]}


def _auth(tokens: dict) -> dict:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


HEALTH = {
    "age_years": 44, "sex_at_birth": "male", "height_cm": 172.0, "weight_kg": 82.0,
    "waist_cm": 102.0, "family_history": "first_degree",
    "physical_activity": "sedentary", "smoker": False,
    "known_high_bp": False, "on_bp_meds": False, "history_high_glucose": False,
    "diabetes_status": "no", "conditions": [], "pregnant": False,
}


# ── ops ───────────────────────────────────────────────────────────────

def test_health_endpoint(client):
    assert client.get("/health").json()["status"] == "ok"


def test_ready_reports_database_and_model(client):
    checks = client.get("/ready").json()["checks"]
    assert checks["database"] == "ok"
    assert "model" in checks


# ── auth ──────────────────────────────────────────────────────────────

def test_signup_creates_an_account_and_a_profile(client):
    user = _signup(client)
    profiles = client.get(f"{API}/profiles", headers=_auth(user["tokens"])).json()
    assert len(profiles) == 1
    assert profiles[0]["display_name"] == "Test User"


def test_signup_requires_accepting_the_disclaimer(client):
    """PRD §3.2 — blocking, not a checkbox we can skip."""
    resp = client.post(f"{API}/auth/signup", json={
        "email": f"u{uuid.uuid4().hex[:12]}@example.com",
        "password": "correct horse battery staple",
        "display_name": "No Consent", "accept_disclaimer": False,
    })
    assert resp.status_code == 400
    assert "disclaimer" in resp.text.lower()


def test_duplicate_email_is_rejected(client):
    user = _signup(client)
    resp = client.post(f"{API}/auth/signup", json={
        "email": user["email"], "password": "another password here",
        "display_name": "Impostor", "accept_disclaimer": True,
    })
    assert resp.status_code == 409


def test_login_returns_tokens(client):
    user = _signup(client)
    resp = client.post(f"{API}/auth/login",
                       json={"email": user["email"], "password": user["password"]})
    assert resp.status_code == 200
    assert resp.json()["access_token"]


def test_wrong_password_is_rejected(client):
    user = _signup(client)
    resp = client.post(f"{API}/auth/login",
                       json={"email": user["email"], "password": "wrong password entirely"})
    assert resp.status_code == 401


def test_login_does_not_reveal_whether_an_email_exists(client):
    """Same message either way, or the endpoint becomes an account enumerator."""
    user = _signup(client)
    known = client.post(f"{API}/auth/login",
                        json={"email": user["email"], "password": "wrong password entirely"})
    unknown = client.post(f"{API}/auth/login",
                          json={"email": "nobody@example.com", "password": "wrong password entirely"})
    assert known.status_code == unknown.status_code == 401
    assert known.json()["detail"] == unknown.json()["detail"]


def test_unauthenticated_requests_are_rejected(client):
    assert client.get(f"{API}/profiles").status_code == 401


def test_a_refresh_token_cannot_be_used_as_an_access_token(client):
    user = _signup(client)
    resp = client.get(f"{API}/profiles", headers={
        "Authorization": f"Bearer {user['tokens']['refresh_token']}"
    })
    assert resp.status_code == 401


# ── health profile and risk ───────────────────────────────────────────

def test_full_slice_signup_to_risk(client):
    """The vertical slice: signup -> health profile -> calibrated percentage."""
    user = _signup(client)
    headers = _auth(user["tokens"])
    profile_id = client.get(f"{API}/profiles", headers=headers).json()[0]["id"]

    saved = client.put(f"{API}/profiles/{profile_id}/health", json=HEALTH, headers=headers)
    assert saved.status_code == 200, saved.text

    resp = client.post(f"{API}/risk/assess",
                       json={"profile_id": profile_id}, headers=headers)
    assert resp.status_code == 200, resp.text
    result = resp.json()

    assert 0.0 <= result["probability"] <= 1.0
    assert result["range_low"] < result["probability"] < result["range_high"]
    assert result["band"] in ("low", "moderate", "high", "very_high")
    assert "not a diagnosis" in result["disclaimer"]
    assert result["modifiable_factors"], "the user needs something they can act on"
    assert result["validation_status"] == "not_validated"      # bd
    assert result["model_version"].startswith("clinical_only:")

    history = client.get(f"{API}/risk/history?profile_id={profile_id}", headers=headers)
    assert len(history.json()) == 1


def test_risk_requires_a_health_profile_first(client):
    user = _signup(client)
    headers = _auth(user["tokens"])
    profile_id = client.get(f"{API}/profiles", headers=headers).json()[0]["id"]
    resp = client.post(f"{API}/risk/assess", json={"profile_id": profile_id}, headers=headers)
    assert resp.status_code == 400


def test_under_18_is_blocked_with_a_safety_card(client):
    """PRD §3.3 — the gate runs before any health data is stored."""
    user = _signup(client)
    headers = _auth(user["tokens"])
    profile_id = client.get(f"{API}/profiles", headers=headers).json()[0]["id"]

    resp = client.put(f"{API}/profiles/{profile_id}/health",
                      json={**HEALTH, "age_years": 15}, headers=headers)
    assert resp.status_code == 403
    card = resp.json()["detail"]["safety_card"]
    assert card["trigger"] == "under_18"


def test_an_already_diagnosed_profile_is_routed_away_from_screening(client):
    """PRD §F1 — diabetes_status routes the whole experience."""
    user = _signup(client)
    headers = _auth(user["tokens"])
    profile_id = client.get(f"{API}/profiles", headers=headers).json()[0]["id"]

    client.put(f"{API}/profiles/{profile_id}/health",
               json={**HEALTH, "diabetes_status": "t2d"}, headers=headers)
    resp = client.post(f"{API}/risk/assess", json={"profile_id": profile_id}, headers=headers)
    assert resp.status_code == 409
    assert resp.json()["detail"]["reason"] == "already_diagnosed"


def test_us_region_uses_the_trained_model(client):
    """The US pack is provisional, so the GBM answers rather than the score alone."""
    user = _signup(client, region="us", locale="en")
    headers = _auth(user["tokens"])
    profile_id = client.get(f"{API}/profiles", headers=headers).json()[0]["id"]
    client.put(f"{API}/profiles/{profile_id}/health", json=HEALTH, headers=headers)

    result = client.post(f"{API}/risk/assess",
                         json={"profile_id": profile_id}, headers=headers).json()
    assert result["validation_status"] == "provisional"
    assert result["clinical_score"] == "ADA"


# ── cross-account isolation, through the API ──────────────────────────

def test_one_user_cannot_read_anothers_profile(client):
    """The same guarantee as test_rls.py, exercised through HTTP."""
    alice = _signup(client)
    bob = _signup(client)
    bob_profile = client.get(f"{API}/profiles", headers=_auth(bob["tokens"])).json()[0]["id"]

    resp = client.post(f"{API}/risk/assess",
                       json={"profile_id": bob_profile}, headers=_auth(alice["tokens"]))
    assert resp.status_code == 404, "must not leak that the profile exists"


def test_one_user_cannot_write_anothers_health_profile(client):
    alice = _signup(client)
    bob = _signup(client)
    bob_profile = client.get(f"{API}/profiles", headers=_auth(bob["tokens"])).json()[0]["id"]

    resp = client.put(f"{API}/profiles/{bob_profile}/health",
                      json=HEALTH, headers=_auth(alice["tokens"]))
    assert resp.status_code == 404


def test_profiles_list_shows_only_your_own(client):
    alice = _signup(client)
    _signup(client)
    profiles = client.get(f"{API}/profiles", headers=_auth(alice["tokens"])).json()
    assert len(profiles) == 1


# ── vitals and the red-flag interceptor ───────────────────────────────

def test_normal_glucose_is_recorded(client):
    user = _signup(client)
    headers = _auth(user["tokens"])
    profile_id = client.get(f"{API}/profiles", headers=headers).json()[0]["id"]

    resp = client.post(f"{API}/vitals", json={
        "profile_id": profile_id, "type": "glucose", "value": 5.5,
        "unit": "mmol/L", "context_tag": "fasting",
    }, headers=headers)
    assert resp.status_code == 201


def test_dangerous_glucose_returns_a_safety_card_but_still_records(client):
    """PRD §3.3 — the card replaces the response; the reading is not lost."""
    user = _signup(client)
    headers = _auth(user["tokens"])
    profile_id = client.get(f"{API}/profiles", headers=headers).json()[0]["id"]

    resp = client.post(f"{API}/vitals", json={
        "profile_id": profile_id, "type": "glucose", "value": 22.0,
        "unit": "mmol/L", "context_tag": "random",
    }, headers=headers)
    assert resp.status_code == 409
    detail = resp.json()["detail"]
    assert detail["safety_card"]["trigger"] == "hyperglycaemia"
    assert detail["safety_card"]["emergency_number"] == "999"     # bd pack
    assert detail["recorded"] is True


def test_hypoglycaemia_is_caught_through_the_api(client):
    user = _signup(client)
    headers = _auth(user["tokens"])
    profile_id = client.get(f"{API}/profiles", headers=headers).json()[0]["id"]

    resp = client.post(f"{API}/vitals", json={
        "profile_id": profile_id, "type": "glucose", "value": 2.9, "unit": "mmol/L",
    }, headers=headers)
    assert resp.status_code == 409
    assert resp.json()["detail"]["safety_card"]["trigger"] == "hypoglycaemia"


def test_mg_dl_units_are_converted_before_screening(client):
    """400 mg/dL is 22.2 mmol/L — the flag must fire regardless of unit."""
    user = _signup(client)
    headers = _auth(user["tokens"])
    profile_id = client.get(f"{API}/profiles", headers=headers).json()[0]["id"]

    resp = client.post(f"{API}/vitals", json={
        "profile_id": profile_id, "type": "glucose", "value": 400.0,
        "unit": "mg/dL", "context_tag": "random",
    }, headers=headers)
    assert resp.status_code == 409


# ── regions ───────────────────────────────────────────────────────────

@pytest.mark.parametrize("code", ["bd", "in", "us", "gb", "de", "ae"])
def test_every_region_pack_is_servable(client, code):
    resp = client.get(f"{API}/regions/{code}/pack")
    assert resp.status_code == 200
    assert resp.json()["code"] == code


def test_unknown_region_returns_404(client):
    assert client.get(f"{API}/regions/zz/pack").status_code == 404


def test_validation_status_is_published(client):
    """PRD §7.4b — markets declare their status honestly."""
    assert client.get(f"{API}/regions/bd/validation").json()["validation_status"] == "not_validated"
    assert client.get(f"{API}/regions/us/validation").json()["validation_status"] == "provisional"
