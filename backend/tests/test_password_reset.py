"""Password reset, the session cut-off it triggers, and the declared cutoff group.

The reset rules come from the handoff (screen "forgot"): the same answer for
every address, a 10-minute code, 5 tries then a 30-minute lock, one code per
60 seconds, and a successful reset signs out every other session.
"""

from __future__ import annotations

import re
import uuid
from datetime import timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text

from app.api import password_reset as reset_module
from app.config import get_settings
from app.db.session import engine
from app.main import app
from app.services import mailer

API = "/api/v1"
PASSWORD = "correct horse battery staple"


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


@pytest.fixture
def outbox(monkeypatch):
    """Captures mail instead of sending it, even if SMTP is configured."""
    sent: list[dict] = []
    monkeypatch.setattr(mailer, "send",
                        lambda to, subject, body: sent.append(
                            {"to": to, "subject": subject, "body": body}))
    monkeypatch.setattr(get_settings(), "environment", "development")
    return sent


def _signup(client, region="bd", locale="en"):
    email = f"pr{uuid.uuid4().hex[:12]}@example.com"
    resp = client.post(f"{API}/auth/signup", json={
        "email": email, "password": PASSWORD, "display_name": "Reset User",
        "region": region, "locale": locale, "accept_terms": True,
    })
    assert resp.status_code == 201, resp.text
    tokens = resp.json()
    return {"email": email, "tokens": tokens,
            "headers": {"Authorization": f"Bearer {tokens['access_token']}"}}


def _code(outbox) -> str:
    assert outbox, "no email was sent"
    match = re.search(r"\b(\d{6})\b", outbox[-1]["body"])
    assert match, outbox[-1]["body"]
    return match.group(1)


def _wrong(code: str) -> str:
    return f"{(int(code) + 1) % 1_000_000:06d}"


def _request(client, email):
    return client.post(f"{API}/auth/password/reset-request", json={"email": email})


def _verify(client, email, code):
    return client.post(f"{API}/auth/password/reset-verify",
                       json={"email": email, "code": code})


def _reason(resp) -> str:
    return resp.json()["detail"]["reason"]


# ── the whole flow ────────────────────────────────────────────────────

def test_reset_changes_the_password_and_signs_out_every_session(client, outbox):
    user = _signup(client)
    assert client.get(f"{API}/me", headers=user["headers"]).status_code == 200

    resp = _request(client, user["email"])
    assert resp.status_code == 202
    assert resp.json() == {"resend_after_seconds": 60}
    assert outbox[-1]["to"] == user["email"]
    code = _code(outbox)

    wrong = _verify(client, user["email"], _wrong(code))
    assert wrong.status_code == 400
    assert _reason(wrong) == "invalid_code"
    assert wrong.json()["detail"]["attempts_left"] == 4

    ok = _verify(client, user["email"], code)
    assert ok.status_code == 200, ok.text
    token = ok.json()["reset_token"]

    done = client.post(f"{API}/auth/password/reset",
                       json={"reset_token": token, "new_password": "a new password 42"})
    assert done.status_code == 204, done.text

    # Every earlier session is over, access and refresh alike.
    assert client.get(f"{API}/me", headers=user["headers"]).status_code == 401
    assert client.post(f"{API}/auth/refresh", json={
        "refresh_token": user["tokens"]["refresh_token"]}).status_code == 401

    # The old password no longer works; the new one does, and its session is live.
    assert client.post(f"{API}/auth/login", json={
        "email": user["email"], "password": PASSWORD}).status_code == 401
    login = client.post(f"{API}/auth/login", json={
        "email": user["email"], "password": "a new password 42"})
    assert login.status_code == 200
    fresh = {"Authorization": f"Bearer {login.json()['access_token']}"}
    assert client.get(f"{API}/me", headers=fresh).status_code == 200

    # A reset token works once.
    again = client.post(f"{API}/auth/password/reset",
                        json={"reset_token": token, "new_password": "another one 77"})
    assert again.status_code == 400
    assert _reason(again) == "invalid_reset_token"


def test_an_unknown_email_gets_the_same_answer_and_no_mail(client, outbox):
    missing = f"nobody{uuid.uuid4().hex[:10]}@example.com"
    resp = _request(client, missing)
    assert resp.status_code == 202
    assert resp.json() == {"resend_after_seconds": 60}
    assert outbox == []

    check = _verify(client, missing, "123456")
    assert check.status_code == 400
    assert _reason(check) == "invalid_code"


def test_a_second_request_inside_a_minute_sends_nothing(client, outbox):
    user = _signup(client)
    assert _request(client, user["email"]).status_code == 202
    first = _code(outbox)
    assert _request(client, user["email"]).status_code == 202
    assert len(outbox) == 1
    # And the first code still works.
    assert _verify(client, user["email"], first).status_code == 200


def test_five_wrong_codes_lock_reset(client, outbox):
    user = _signup(client)
    _request(client, user["email"])
    code = _code(outbox)
    for _ in range(4):
        assert _verify(client, user["email"], _wrong(code)).status_code == 400
    fifth = _verify(client, user["email"], _wrong(code))
    assert fifth.status_code == 429
    assert _reason(fifth) == "too_many_attempts"

    # Locked means locked: even the right code is refused now, and no new
    # code is sent.
    assert _verify(client, user["email"], code).status_code == 429
    _request(client, user["email"])
    assert len(outbox) == 1


def test_an_expired_code_is_refused(client, outbox, monkeypatch):
    monkeypatch.setattr(reset_module, "CODE_TTL", timedelta(seconds=-1))
    user = _signup(client)
    _request(client, user["email"])
    resp = _verify(client, user["email"], _code(outbox))
    assert resp.status_code == 400
    assert _reason(resp) == "invalid_code"


def test_bangla_digits_are_accepted(client, outbox):
    user = _signup(client, locale="bn")
    _request(client, user["email"])
    assert "রিসেট" in outbox[-1]["subject"]
    code = _code(outbox)
    bangla = code.translate(str.maketrans("0123456789", "০১২৩৪৫৬৭৮৯"))
    assert _verify(client, user["email"], bangla).status_code == 200


def test_a_forged_or_wrong_type_token_is_refused(client, outbox):
    user = _signup(client)
    # An access token is a valid JWT, but not a reset token.
    resp = client.post(f"{API}/auth/password/reset", json={
        "reset_token": user["tokens"]["access_token"], "new_password": "whatever 123"})
    assert resp.status_code == 400
    assert _reason(resp) == "invalid_reset_token"


def test_production_without_email_refuses_every_address_alike(client, outbox, monkeypatch):
    settings = get_settings()
    monkeypatch.setattr(settings, "environment", "production")
    monkeypatch.setattr(settings, "smtp_host", "")
    user = _signup(client)
    for email in (user["email"], f"nobody{uuid.uuid4().hex[:8]}@example.com"):
        resp = _request(client, email)
        assert resp.status_code == 503
        assert _reason(resp) == "reset_unavailable"
    assert outbox == []


# ── declared cutoff group (the diaspora fix) ──────────────────────────

def _health(client, user, **extra):
    profile_id = client.get(f"{API}/profiles", headers=user["headers"]).json()[0]["id"]
    client.post(f"{API}/consents", json={"kind": "medical_disclaimer"},
                headers=user["headers"])
    body = {
        "age_years": 50, "sex_at_birth": "male", "height_cm": 170.0, "weight_kg": 76.0,
        "waist_cm": 92.0, "family_history": "none", "physical_activity": "light",
        "smoker": False, "known_high_bp": False, "on_bp_meds": False,
        "history_high_glucose": False, "diabetes_status": "no", "conditions": [],
        "pregnant": False, **extra,
    }
    resp = client.put(f"{API}/profiles/{profile_id}/health", headers=user["headers"], json=body)
    return profile_id, resp


def test_a_declared_group_is_stored_and_changes_the_cutoffs(client):
    """A Bangladeshi in London: scored on South Asian cutoffs once declared."""
    user = _signup(client, region="gb")
    profile_id, resp = _health(client, user)
    assert resp.status_code == 200, resp.text
    assert resp.json()["ancestry_cutoff_group"] is None
    default = client.post(f"{API}/risk/assess", headers=user["headers"],
                          json={"profile_id": profile_id}).json()

    profile_id, resp = _health(client, user, ancestry_cutoff_group="south_asian")
    assert resp.status_code == 200, resp.text
    assert resp.json()["ancestry_cutoff_group"] == "south_asian"
    declared = client.post(f"{API}/risk/assess", headers=user["headers"],
                           json={"profile_id": profile_id}).json()

    assert default["clinical_score"] == "FINDRISC"
    assert declared["clinical_score"] == "IDRS"
    assert any("South Asian" in c for c in declared["caveats"])


def test_an_unknown_group_is_rejected(client):
    user = _signup(client)
    _, resp = _health(client, user, ancestry_cutoff_group="martian")
    assert resp.status_code == 422
