"""The tracker's tools: search by any name, recent/frequent/favourites, ± on a
logged item, "same as yesterday", water, and the goal sheet.

The goal sheet is the safety-relevant one: a user-typed goal is a request,
and the §5.4 rails still decide the target.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime, time, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text

from app.db.session import engine
from app.main import app

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


def _signup(client, sex="male", weight=82.0, height=172.0):
    resp = client.post(f"{API}/auth/signup", json={
        "email": f"tt{uuid.uuid4().hex[:12]}@example.com",
        "password": "correct horse battery staple",
        "display_name": "Tools User", "region": "bd", "locale": "en",
        "accept_terms": True,
    })
    assert resp.status_code == 201, resp.text
    headers = {"Authorization": f"Bearer {resp.json()['access_token']}"}
    client.post(f"{API}/consents", json={"kind": "medical_disclaimer"}, headers=headers)
    profile_id = client.get(f"{API}/profiles", headers=headers).json()[0]["id"]
    client.put(f"{API}/profiles/{profile_id}/health", headers=headers, json={
        "age_years": 44, "sex_at_birth": sex, "height_cm": height, "weight_kg": weight,
        "waist_cm": 98.0, "family_history": "none", "physical_activity": "sedentary",
        "smoker": False, "known_high_bp": False, "on_bp_meds": False,
        "history_high_glucose": False, "diabetes_status": "no", "conditions": [],
        "pregnant": False,
    })
    return {"headers": headers, "profile_id": profile_id}


@pytest.fixture
def user(client):
    return _signup(client)


def _food(client, user, q):
    rows = client.get(f"{API}/foods", headers=user["headers"], params={"q": q}).json()
    assert rows, f"no food for {q!r}"
    return rows[0]


def _log(client, user, food, slot="lunch", quantity=1.0, unit="serving", on=None):
    body = {"profile_id": user["profile_id"], "slot": slot,
            "items": [{"food_id": food["id"], "name": food["name_en"],
                       "quantity": quantity, "unit": unit}]}
    if on is not None:
        body["eaten_at"] = datetime.combine(on, time(13, 0), tzinfo=timezone.utc).isoformat()
    resp = client.post(f"{API}/meals", headers=user["headers"], json=body)
    assert resp.status_code == 201, resp.text
    return resp.json()


# ── search ────────────────────────────────────────────────────────────

@pytest.mark.parametrize("query,expected", [
    ("murgir jhol", "Chicken curry"),     # transliteration
    ("মুরগির", "Chicken curry"),           # Bangla
    ("chicken", "Chicken curry"),         # English
    ("bhat", "Boiled rice"),
    ("ডাল", "Lentil dal"),
])
def test_food_search_understands_bangla_english_and_transliteration(
        client, user, query, expected):
    names = [f["name_en"] for f in client.get(
        f"{API}/foods", headers=user["headers"], params={"q": query}).json()]
    assert expected in names


# ── recent, frequent, favourites ──────────────────────────────────────

def test_recent_and_frequent_come_from_this_profiles_own_log(client, user):
    rice, dal = _food(client, user, "bhat"), _food(client, user, "dal")
    _log(client, user, rice)
    _log(client, user, rice)
    _log(client, user, dal)

    p = {"profile_id": user["profile_id"]}
    recent = [f["id"] for f in client.get(f"{API}/foods/recent",
                                          headers=user["headers"], params=p).json()]
    frequent = [f["id"] for f in client.get(f"{API}/foods/frequent",
                                            headers=user["headers"], params=p).json()]
    assert recent[0] == dal["id"]
    assert frequent[0] == rice["id"]

    # Another user's log never shows up.
    other = _signup(client)
    assert client.get(f"{API}/foods/recent", headers=other["headers"],
                      params={"profile_id": other["profile_id"]}).json() == []


def test_favourites_round_trip(client, user):
    dal = _food(client, user, "dal")
    p = {"profile_id": user["profile_id"]}
    url = f"{API}/foods/{dal['id']}/favourite"
    assert client.put(url, headers=user["headers"], params=p).status_code == 204
    assert client.put(url, headers=user["headers"], params=p).status_code == 204  # idempotent
    favs = client.get(f"{API}/foods/favourites", headers=user["headers"], params=p).json()
    assert [f["id"] for f in favs] == [dal["id"]]
    assert client.delete(url, headers=user["headers"], params=p).status_code == 204
    assert client.get(f"{API}/foods/favourites", headers=user["headers"],
                      params=p).json() == []


# ── ± on a logged item ────────────────────────────────────────────────

def test_changing_a_portion_scales_its_nutrition(client, user):
    meal = _log(client, user, _food(client, user, "bhat"), quantity=1, unit="cup")
    item = meal["items"][0]
    resp = client.patch(f"{API}/meals/{meal['id']}/items/{item['id']}",
                        headers=user["headers"], json={"quantity": 2})
    assert resp.status_code == 200, resp.text
    doubled = resp.json()["items"][0]
    assert doubled["quantity"] == 2
    assert doubled["grams"] == pytest.approx(item["grams"] * 2, abs=0.2)
    assert doubled["kcal"] == pytest.approx(item["kcal"] * 2, abs=1)
    assert resp.json()["kcal_low"] < resp.json()["kcal"] < resp.json()["kcal_high"]


def test_removing_the_last_item_removes_the_meal(client, user):
    meal = _log(client, user, _food(client, user, "dal"))
    item = meal["items"][0]
    assert client.delete(f"{API}/meals/{meal['id']}/items/{item['id']}",
                         headers=user["headers"]).status_code == 204
    meals = client.get(f"{API}/meals", headers=user["headers"],
                       params={"profile_id": user["profile_id"]}).json()
    assert all(m["id"] != meal["id"] for m in meals)


def test_another_profile_cannot_edit_my_item(client, user):
    meal = _log(client, user, _food(client, user, "dal"))
    other = _signup(client)
    resp = client.patch(f"{API}/meals/{meal['id']}/items/{meal['items'][0]['id']}",
                        headers=other["headers"], json={"quantity": 9})
    assert resp.status_code == 404


# ── same as yesterday ─────────────────────────────────────────────────

def test_same_as_yesterday_copies_one_slot(client, user):
    today = date.today()
    yesterday = today - timedelta(days=1)
    rice = _food(client, user, "bhat")
    _log(client, user, rice, slot="lunch", quantity=2, unit="cup", on=yesterday)
    _log(client, user, rice, slot="dinner", on=yesterday)

    resp = client.post(f"{API}/meals/copy", headers=user["headers"], json={
        "profile_id": user["profile_id"], "from_day": yesterday.isoformat(),
        "to_day": today.isoformat(), "slot": "lunch",
    })
    assert resp.status_code == 201, resp.text
    copied = resp.json()
    assert len(copied) == 1 and copied[0]["slot"] == "lunch"
    assert copied[0]["eaten_on"] == today.isoformat()
    assert copied[0]["items"][0]["quantity"] == 2

    nothing = client.post(f"{API}/meals/copy", headers=user["headers"], json={
        "profile_id": user["profile_id"], "from_day": yesterday.isoformat(),
        "to_day": today.isoformat(), "slot": "breakfast",
    })
    assert nothing.status_code == 404


# ── water ─────────────────────────────────────────────────────────────

def test_water_is_a_daily_total(client, user):
    p = user["profile_id"]
    for glasses in (3, 5):
        out = client.put(f"{API}/water", headers=user["headers"],
                         json={"profile_id": p, "glasses": glasses}).json()
    assert out["glasses"] == 5 and out["goal_glasses"] == 8 and out["ml_per_glass"] == 250
    plan = client.get(f"{API}/plan/today", headers=user["headers"],
                      params={"profile_id": p}).json()
    assert plan["water"]["glasses"] == 5
    assert client.put(f"{API}/water", headers=user["headers"],
                      json={"profile_id": p, "glasses": 99}).status_code == 422


# ── the goal sheet ────────────────────────────────────────────────────

def test_a_goal_is_used_when_it_is_safe(client, user):
    p = user["profile_id"]
    target = client.put(f"{API}/plan/goal", headers=user["headers"],
                        json={"profile_id": p, "kcal": 2000}).json()
    assert target["goal_kcal"] == 2000
    assert target["kcal"] == 2000
    assert target["glycemic_load_ceiling"] == 80

    reset = client.put(f"{API}/plan/goal", headers=user["headers"],
                       json={"profile_id": p, "kcal": None}).json()
    assert reset["goal_kcal"] is None


def test_a_goal_below_the_safety_floor_is_raised_not_obeyed(client):
    """A wrong number typed once must not be able to starve someone (§5.4)."""
    u = _signup(client, sex="male", weight=95.0, height=180.0)
    target = client.put(f"{API}/plan/goal", headers=u["headers"],
                        json={"profile_id": u["profile_id"], "kcal": 1200}).json()
    assert target["goal_kcal"] == 1200
    assert target["kcal"] > 1200
    assert target["was_clamped"] is True


def test_the_goal_sheet_range_is_enforced(client, user):
    for bad in (900, 5000):
        assert client.put(f"{API}/plan/goal", headers=user["headers"], json={
            "profile_id": user["profile_id"], "kcal": bad}).status_code == 422
