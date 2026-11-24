"""The two features backed by the OpenRouter model: the coach and the camera.

The model is faked in every test here — no test reaches OpenRouter. What is
tested is everything around the model, which is where the safety lives:

  * the coach is handed the user's own data without the user typing it in
  * the guards still run before the model, and a safety message is never
    model-decided
  * a dose in a model reply never reaches the user
  * the camera's items are proposals; matched items use the food table, and
    nothing is stored until the meal is confirmed
  * with the model down, both features fall back instead of failing
"""

from __future__ import annotations

import base64
import json
import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text

from app.config import get_settings
from app.db.session import engine
from app.main import app
from app.services import coach as coach_service
from app.services import food_vision, llm

API = "/api/v1"

# A real (1×1) JPEG header followed by padding — enough to pass the format check.
JPEG = base64.b64encode(b"\xff\xd8\xff\xe0" + b"\x00" * 400).decode()


def _database_available() -> bool:
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return True
    except Exception:
        return False


needs_db = pytest.mark.skipif(not _database_available(), reason="no database")


@pytest.fixture
def model(monkeypatch):
    """Switch the model on and record what it was sent."""
    monkeypatch.setattr(get_settings(), "openrouter_api_key", "test-key")
    calls: list[dict] = []
    replies: list[str] = []

    def fake_chat(messages, **kwargs):
        calls.append({"messages": messages, **kwargs})
        if not replies:
            raise llm.LLMUnavailable("no reply queued")
        return replies.pop(0)

    monkeypatch.setattr(llm, "chat", fake_chat)
    return {"calls": calls, "replies": replies}


# ── pure units ────────────────────────────────────────────────────────

def test_parse_json_tolerates_a_markdown_fence():
    assert llm.parse_json('```json\n{"a": 1}\n```') == {"a": 1}
    assert llm.parse_json('Here you go: {"a": 2} hope that helps') == {"a": 2}
    with pytest.raises(llm.LLMUnavailable):
        llm.parse_json("no json here")


def test_decode_image_rejects_non_images():
    with pytest.raises(food_vision.InvalidImage):
        food_vision.decode_image(base64.b64encode(b"hello" * 40).decode())
    with pytest.raises(food_vision.InvalidImage):
        food_vision.decode_image("not base64 at all!!")
    assert food_vision.decode_image("data:image/jpeg;base64," + JPEG)[:3] == b"\xff\xd8\xff"


def test_boxes_on_a_thousand_grid_are_rescaled():
    assert food_vision._box([100, 200, 300, 400]) == [0.1, 0.2, 0.3, 0.4]
    assert food_vision._box([0.1, 0.2, 0.3, 0.4]) == [0.1, 0.2, 0.3, 0.4]
    assert food_vision._box([0, 0, 0, 0]) is None
    assert food_vision._box("nope") is None


def test_coach_guards_run_before_the_model(model):
    """A safety message is never the model's decision."""
    reply = coach_service.respond("I have chest pain and feel faint", {"text": ""})
    assert reply.intercepted
    assert model["calls"] == []

    reply = coach_service.respond("how much insulin should I take?", {"text": ""})
    assert reply.intercepted and "doctor" in reply.body.lower()
    assert model["calls"] == []


def test_a_dose_in_a_model_reply_is_never_shown(model):
    model["replies"].append("Try 500 mg of metformin twice a day.")
    reply = coach_service.respond("what helps my sugar?", {"text": "", "history": []})
    assert "500" not in reply.body
    assert reply.intercepted


def test_coach_falls_back_when_the_model_is_down(model):
    # No reply queued: the fake raises LLMUnavailable.
    reply = coach_service.respond("how are my steps?", {"mean_steps": 6400})
    assert reply.model_backed is False
    assert "6400" in reply.body


# ── through the API ───────────────────────────────────────────────────

@pytest.fixture(scope="module")
def client():
    with TestClient(app) as c:
        yield c


@pytest.fixture
def user(client):
    resp = client.post(f"{API}/auth/signup", json={
        "email": f"llm{uuid.uuid4().hex[:12]}@example.com",
        "password": "correct horse battery staple",
        "display_name": "Rahima", "region": "bd", "locale": "bn",
        "accept_terms": True,
    })
    assert resp.status_code == 201, resp.text
    headers = {"Authorization": f"Bearer {resp.json()['access_token']}"}
    client.post(f"{API}/consents", json={"kind": "medical_disclaimer"}, headers=headers)
    profile_id = client.get(f"{API}/profiles", headers=headers).json()[0]["id"]
    client.put(f"{API}/profiles/{profile_id}/health", headers=headers, json={
        "age_years": 46, "sex_at_birth": "female", "height_cm": 155.0,
        "weight_kg": 68.0, "waist_cm": 94.0, "family_history": "first_degree",
        "physical_activity": "light", "smoker": False, "known_high_bp": True,
        "on_bp_meds": True, "history_high_glucose": False, "diabetes_status": "no",
        "conditions": [], "pregnant": False,
    })
    return {"headers": headers, "profile_id": profile_id}


@needs_db
def test_the_coach_already_has_the_users_data(client, user, model):
    """The user never types their own numbers in — the server hands them over."""
    h, pid = user["headers"], user["profile_id"]
    client.post(f"{API}/vitals", headers=h, json={
        "profile_id": pid, "type": "glucose", "value": 6.3, "unit": "mmol/L",
        "context_tag": "fasting",
    })
    client.post(f"{API}/activity", headers=h, json={
        "profile_id": pid, "steps": 7321, "active_minutes": 34,
    })
    rice = next(f for f in client.get(f"{API}/foods", headers=h,
                                      params={"q": "rice"}).json())
    client.post(f"{API}/meals", headers=h, json={
        "profile_id": pid, "slot": "lunch",
        "items": [{"food_id": rice["id"], "name": rice["name_en"],
                   "quantity": 2, "unit": "cup"}],
    })

    model["replies"].append("আপনার আজকের হাঁটা ভালো হয়েছে।")
    resp = client.post(f"{API}/coach/message", headers=h, json={
        "profile_id": pid, "message": "আমার অবস্থা কেমন?",
    })
    assert resp.status_code == 200, resp.text
    out = resp.json()
    assert out["model_backed"] is True
    assert out["reply"] == "আপনার আজকের হাঁটা ভালো হয়েছে।"
    assert "your logged meals" in out["cited"]

    sent = json.dumps(model["calls"][0]["messages"], ensure_ascii=False)
    for fact in ("Rahima", "155", "68", "94", "6.3", "7321", rice["name_en"],
                 "known high blood pressure: yes"):
        assert fact in sent, f"{fact!r} was not given to the model"


@needs_db
def test_the_coach_sees_the_conversation_so_far(client, user, model):
    h, pid = user["headers"], user["profile_id"]
    model["replies"] += ["first answer", "second answer"]
    client.post(f"{API}/coach/message", headers=h,
                json={"profile_id": pid, "message": "first question"})
    client.post(f"{API}/coach/message", headers=h,
                json={"profile_id": pid, "message": "second question"})
    second = model["calls"][1]["messages"]
    contents = [m["content"] for m in second if isinstance(m["content"], str)]
    assert "first question" in contents and "first answer" in contents
    assert contents[-1] == "second question"
    assert contents.count("second question") == 1


@needs_db
def test_recognition_proposes_items_and_saves_nothing(client, user, model):
    h, pid = user["headers"], user["profile_id"]
    rice = next(f for f in client.get(f"{API}/foods", headers=h,
                                      params={"q": "rice"}).json())
    model["replies"].append(json.dumps({
        "is_food": True, "scale_reference": True,
        "items": [
            {"name_en": "Boiled rice", "name_bn": "ভাত", "match": rice["name_en"],
             "quantity": 1.5, "unit": "cup", "grams": 240, "confidence": 0.9,
             "box": [100, 150, 400, 350]},
            {"name_en": "Shorshe ilish", "name_bn": "সর্ষে ইলিশ", "match": None,
             "quantity": 1, "unit": "piece", "grams": 110, "confidence": 0.4,
             "per_100g": {"kcal": 260, "carbs_g": 3, "protein_g": 20,
                          "fat_g": 19, "fibre_g": 0.5}},
        ],
    }))
    meals_before = client.get(f"{API}/meals", headers=h, params={"profile_id": pid}).json()

    resp = client.post(f"{API}/food/recognize", headers=h,
                       params={"profile_id": pid}, json={"image_base64": JPEG})
    assert resp.status_code == 200, resp.text
    out = resp.json()
    assert out["model_available"] is True and out["scale_reference"] is True
    matched, estimated = out["items"]

    assert matched["food_id"] == rice["id"]
    assert matched["source"] == "table"
    assert matched["kcal_per_100g"] == rice["kcal_per_100g"]
    assert matched["box"] == [0.1, 0.15, 0.4, 0.35]
    assert matched["needs_review"] is False

    assert estimated["food_id"] is None and estimated["source"] == "ai_estimate"
    assert estimated["glycemic_index"] is None
    assert estimated["needs_review"] is True

    assert 0 < out["kcal_low"] < out["kcal_high"]
    # The image went to the model as an image part.
    parts = model["calls"][0]["messages"][0]["content"]
    assert any(p.get("type") == "image_url" for p in parts)
    # And nothing was stored.
    assert client.get(f"{API}/meals", headers=h,
                      params={"profile_id": pid}).json() == meals_before

    # The user confirms: the unmatched dish keeps the camera's composition.
    saved = client.post(f"{API}/meals", headers=h, json={
        "profile_id": pid, "slot": "lunch", "entry_method": "photo",
        "items": [{
            "name": estimated["name"], "quantity": 1, "unit": "piece",
            "grams": 110, "recognition_confidence": estimated["confidence"],
            "kcal_per_100g": 260, "carbs_g_per_100g": 3, "protein_g_per_100g": 20,
            "fat_g_per_100g": 19, "fibre_g_per_100g": 0.5,
        }],
    })
    assert saved.status_code == 201, saved.text
    item = saved.json()["items"][0]
    assert item["kcal"] == pytest.approx(286, abs=1)
    assert item["glycemic_load"] is None


@needs_db
def test_recognition_without_a_model_falls_back(client, user):
    out = client.post(f"{API}/food/recognize", headers=user["headers"],
                      params={"profile_id": user["profile_id"]},
                      json={"image_base64": JPEG}).json()
    assert out["model_available"] is False and out["items"] == []


@needs_db
def test_recognition_rejects_a_file_that_is_not_a_photo(client, user, model):
    resp = client.post(f"{API}/food/recognize", headers=user["headers"],
                       params={"profile_id": user["profile_id"]},
                       json={"image_base64": base64.b64encode(b"x" * 300).decode()})
    assert resp.status_code == 422
    assert model["calls"] == []
