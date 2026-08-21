"""Meals, check-ins, activity, coach, insights, reports and billing.

The screens these serve are the second half of the app. The tests below are
weighted towards the things that would hurt someone or get the app pulled:
the safety rails on a calorie target, the red-flag interceptor on a check-in,
the coach's refusal to talk about medication, and the promise that a range is
never collapsed to a single number.
"""

from __future__ import annotations

import sys
import uuid
from datetime import date, timedelta
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import text

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.db.models import COACH_FREE_DAILY_LIMIT  # noqa: E402
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


HEALTH = {
    "age_years": 44, "sex_at_birth": "male", "height_cm": 172.0, "weight_kg": 82.0,
    "waist_cm": 102.0, "family_history": "first_degree",
    "physical_activity": "sedentary", "smoker": False,
    "known_high_bp": False, "on_bp_meds": False, "history_high_glucose": False,
    "diabetes_status": "no", "conditions": [], "pregnant": False,
}


def _auth(tokens: dict) -> dict:
    return {"Authorization": f"Bearer {tokens['access_token']}"}


@pytest.fixture
def user(client):
    """A signed-up account past both consents, with a completed health profile."""
    resp = client.post(f"{API}/auth/signup", json={
        "email": f"t{uuid.uuid4().hex[:12]}@example.com",
        "password": "correct horse battery staple",
        "display_name": "Tracker User", "region": "bd", "locale": "en",
        "accept_terms": True,
    })
    assert resp.status_code == 201, resp.text
    tokens = resp.json()
    headers = _auth(tokens)
    client.post(f"{API}/consents", json={"kind": "medical_disclaimer"}, headers=headers)
    profile_id = client.get(f"{API}/profiles", headers=headers).json()[0]["id"]
    client.put(f"{API}/profiles/{profile_id}/health", json=HEALTH, headers=headers)
    return {"headers": headers, "profile_id": profile_id}


# ── food reference data ───────────────────────────────────────────────

def test_foods_are_searchable_and_declare_their_provenance(client, user):
    foods = client.get(f"{API}/foods", params={"q": "rice"},
                       headers=user["headers"]).json()
    assert foods, "the starter set should contain rice"
    # Every seeded row must say it is a placeholder, so the UI cannot present
    # an approximation as a licensed composition value.
    assert all(f["source"] == "placeholder" for f in foods)
    assert all("portion_grams" in f for f in foods)


def test_a_food_without_a_known_gi_gets_no_glycemic_load(client, user):
    """A guessed glycemic load on a diabetes app is worse than an absent one."""
    foods = client.get(f"{API}/foods", params={"q": "paratha"},
                       headers=user["headers"]).json()
    assert foods and foods[0]["glycemic_index"] is None

    meal = client.post(f"{API}/meals", headers=user["headers"], json={
        "profile_id": user["profile_id"], "slot": "breakfast",
        "items": [{"food_id": foods[0]["id"], "name": "Paratha",
                   "quantity": 1, "unit": "piece"}],
    }).json()
    assert meal["glycemic_load"] is None


# ── meals ─────────────────────────────────────────────────────────────

def test_logging_a_meal_computes_nutrition_from_the_local_portion(client, user):
    rice = client.get(f"{API}/foods", params={"q": "Boiled rice"},
                      headers=user["headers"]).json()[0]
    meal = client.post(f"{API}/meals", headers=user["headers"], json={
        "profile_id": user["profile_id"], "slot": "lunch",
        "items": [{"food_id": rice["id"], "name": "Boiled rice",
                   "quantity": 1, "unit": "bowl"}],
    })
    assert meal.status_code == 201, meal.text
    body = meal.json()
    # One bowl is 200g at 130 kcal/100g.
    assert body["items"][0]["grams"] == pytest.approx(200, abs=1)
    assert body["kcal"] == pytest.approx(260, abs=2)
    assert body["glycemic_load"] is not None


def test_calories_are_returned_as_a_range_not_a_bare_number(client, user):
    rice = client.get(f"{API}/foods", params={"q": "Boiled rice"},
                      headers=user["headers"]).json()[0]
    body = client.post(f"{API}/meals", headers=user["headers"], json={
        "profile_id": user["profile_id"], "slot": "dinner",
        "items": [{"food_id": rice["id"], "name": "Boiled rice",
                   "quantity": 1, "unit": "cup"}],
    }).json()
    assert body["kcal_low"] < body["kcal"] < body["kcal_high"]


def test_a_photo_meal_carries_a_wider_band_than_a_manual_one(client, user):
    """A photograph of a plate of rice is not known to the calorie."""
    rice = client.get(f"{API}/foods", params={"q": "Boiled rice"},
                      headers=user["headers"]).json()[0]
    item = {"food_id": rice["id"], "name": "Boiled rice",
            "quantity": 1, "unit": "bowl"}

    manual = client.post(f"{API}/meals", headers=user["headers"], json={
        "profile_id": user["profile_id"], "slot": "lunch",
        "items": [item], "entry_method": "manual"}).json()
    photo = client.post(f"{API}/meals", headers=user["headers"], json={
        "profile_id": user["profile_id"], "slot": "snack",
        "items": [item], "entry_method": "photo"}).json()

    manual_width = manual["kcal_high"] - manual["kcal_low"]
    photo_width = photo["kcal_high"] - photo["kcal_low"]
    assert photo_width > manual_width


def test_glycemic_load_uses_available_carbs_not_total_weight(client, user):
    """Fibre is carbohydrate the body does not turn into glucose.

    Dal is high fibre; counting it would overstate the load on exactly the
    foods this product wants to encourage.
    """
    dal = client.get(f"{API}/foods", params={"q": "dal"},
                     headers=user["headers"]).json()[0]
    meal = client.post(f"{API}/meals", headers=user["headers"], json={
        "profile_id": user["profile_id"], "slot": "lunch",
        "items": [{"food_id": dal["id"], "name": "Dal",
                   "quantity": 1, "unit": "bowl"}],
    }).json()
    item = meal["items"][0]
    naive = dal["glycemic_index"] * item["carbs_g"] / 100
    assert item["glycemic_load"] < naive


def test_meals_are_listed_for_a_day_and_can_be_deleted(client, user):
    rice = client.get(f"{API}/foods", params={"q": "Boiled rice"},
                      headers=user["headers"]).json()[0]
    created = client.post(f"{API}/meals", headers=user["headers"], json={
        "profile_id": user["profile_id"], "slot": "breakfast",
        "items": [{"food_id": rice["id"], "name": "Boiled rice",
                   "quantity": 1, "unit": "cup"}],
    }).json()

    listed = client.get(f"{API}/meals", headers=user["headers"],
                        params={"profile_id": user["profile_id"]}).json()
    assert any(m["id"] == created["id"] for m in listed)

    assert client.delete(f"{API}/meals/{created['id']}",
                         headers=user["headers"]).status_code == 204
    listed = client.get(f"{API}/meals", headers=user["headers"],
                        params={"profile_id": user["profile_id"]}).json()
    assert not any(m["id"] == created["id"] for m in listed)


def test_recognition_admits_there_is_no_model(client, user):
    """Returning invented items on a food-and-blood-sugar screen would harm."""
    out = client.post(f"{API}/food/recognize", headers=user["headers"],
                      params={"profile_id": user["profile_id"]}).json()
    assert out["model_available"] is False
    assert out["items"] == []
    assert out["confidence_floor"] > 0


# ── the day's plan and the §5.4 rails ─────────────────────────────────

def test_plan_today_returns_targets_totals_and_meals(client, user):
    plan = client.get(f"{API}/plan/today", headers=user["headers"],
                      params={"profile_id": user["profile_id"]}).json()
    assert plan["target"] is not None
    assert plan["target"]["kcal"] >= 1500  # male floor
    assert plan["totals"]["kcal_low"] <= plan["totals"]["kcal_high"]


def test_the_calorie_target_can_never_go_below_the_absolute_floor(client):
    """PRD §3.6 — a wrong number typed once must not be able to starve someone.

    A very small, very sedentary profile would otherwise compute a target under
    the floor; `clamp_calorie_target` is the only path to a kcal figure.
    """
    from app.services.nutrition import daily_target

    target = daily_target(sex="female", weight_kg=38, height_cm=145, age=70,
                          activity="sedentary", goal="lose", bmi=18.1)
    assert target.kcal >= 1200
    # Below the BMI floor, weight loss is off entirely and the target is
    # maintenance rather than a deficit.
    assert target.weight_loss_disabled is True
    assert target.was_clamped is True


def test_a_deficit_is_capped_at_500_kcal_below_maintenance(client):
    from app.services.nutrition import daily_target

    target = daily_target(sex="male", weight_kg=95, height_cm=180, age=40,
                          activity="active", goal="lose", bmi=29.3)
    assert target.maintenance_kcal - target.kcal <= 500


# ── check-ins ─────────────────────────────────────────────────────────

def test_a_checkin_is_upserted_per_day(client, user):
    body = {"profile_id": user["profile_id"], "energy": 3, "sleep_hours": 7.0}
    first = client.post(f"{API}/checkins", json=body, headers=user["headers"]).json()
    body["energy"] = 5
    second = client.post(f"{API}/checkins", json=body, headers=user["headers"]).json()
    assert first["id"] == second["id"], "a second submission updates the same day"
    assert second["energy"] == 5

    today = client.get(f"{API}/checkins/today", headers=user["headers"],
                       params={"profile_id": user["profile_id"]}).json()
    assert today["energy"] == 5


def test_a_symptom_cluster_routes_to_a_safety_card_and_still_records(client, user):
    resp = client.post(f"{API}/checkins", headers=user["headers"], json={
        "profile_id": user["profile_id"], "energy": 2,
        "symptoms": ["blurred_vision", "excessive_thirst"],
    })
    # A warning does not block the response; it is "write it down and take it
    # with you", not "go to hospital".
    assert resp.status_code == 201
    stored = client.get(f"{API}/checkins/today", headers=user["headers"],
                        params={"profile_id": user["profile_id"]}).json()
    assert set(stored["symptoms"]) == {"blurred_vision", "excessive_thirst"}


def test_an_emergency_phrase_in_a_checkin_note_intercepts(client, user):
    resp = client.post(f"{API}/checkins", headers=user["headers"], json={
        "profile_id": user["profile_id"], "energy": 2,
        "note": "woke up with chest pain and could not breathe",
    })
    assert resp.status_code == 409
    detail = resp.json()["detail"]
    assert detail["safety_card"]["severity"] == "emergency"
    # The check-in WAS recorded — refusing to store it would lose the history.
    assert detail["recorded"] is True


# ── activity ──────────────────────────────────────────────────────────

def test_activity_is_upserted_not_appended(client, user):
    """A platform reports a running daily total; appending would double-count."""
    body = {"profile_id": user["profile_id"], "steps": 3000, "active_minutes": 20}
    client.post(f"{API}/activity", json=body, headers=user["headers"])
    body["steps"] = 7400
    client.post(f"{API}/activity", json=body, headers=user["headers"])

    rows = client.get(f"{API}/activity", headers=user["headers"],
                      params={"profile_id": user["profile_id"]}).json()
    today_rows = [r for r in rows if r["activity_on"] == date.today().isoformat()]
    assert len(today_rows) == 1
    assert today_rows[0]["steps"] == 7400


def test_repeated_same_day_writes_never_500(client, user):
    """Regression: SELECT-then-INSERT raced its own unique constraint.

    A transaction cannot see a row another in-flight request has inserted but
    not committed, so both decided to INSERT and the second violated
    `uq_activity_profile_day` / `uq_checkin_profile_day`. A health platform
    syncs in bursts, so this was a 500 on the ordinary path, not an edge case.
    Both endpoints now use INSERT ... ON CONFLICT DO UPDATE.
    """
    for steps in range(1000, 6000, 1000):
        resp = client.post(f"{API}/activity", headers=user["headers"], json={
            "profile_id": user["profile_id"], "steps": steps})
        assert resp.status_code == 200, resp.text

    for energy in (1, 2, 3, 4, 5):
        resp = client.post(f"{API}/checkins", headers=user["headers"], json={
            "profile_id": user["profile_id"], "energy": energy})
        assert resp.status_code == 201, resp.text

    # Still exactly one row per day, carrying the last value written.
    activity = client.get(f"{API}/activity", headers=user["headers"],
                          params={"profile_id": user["profile_id"]}).json()
    today = [r for r in activity if r["activity_on"] == date.today().isoformat()]
    assert len(today) == 1 and today[0]["steps"] == 5000

    checkin = client.get(f"{API}/checkins/today", headers=user["headers"],
                         params={"profile_id": user["profile_id"]}).json()
    assert checkin["energy"] == 5


# ── vitals, read side ─────────────────────────────────────────────────

def test_an_intercepted_reading_is_actually_stored_not_just_claimed(client, user):
    """Regression, and the worst bug in this codebase so far.

    `db_session` rolls back on any exception, and an HTTPException raised from
    a route IS an exception — so the 409 that carries `"recorded": true` was
    undoing the very row it claimed to have stored. The response said saved;
    the database had nothing.

    A person logs a dangerous glucose reading, is told it has been recorded,
    takes their phone to a doctor, and there is no record. This test asserts
    the promise by RE-READING, never by trusting the flag.
    """
    resp = client.post(f"{API}/vitals", headers=user["headers"], json={
        "profile_id": user["profile_id"], "type": "glucose",
        "value": 17.2, "unit": "mmol/L", "context_tag": "fasting",
    })
    assert resp.status_code == 409
    detail = resp.json()["detail"]
    assert detail["safety_card"]["severity"] == "urgent"
    assert detail["recorded"] is True

    stored = client.get(f"{API}/vitals", headers=user["headers"],
                        params={"profile_id": user["profile_id"],
                                "type": "glucose"}).json()
    assert any(abs(r["value"] - 17.2) < 0.01 for r in stored), (
        "the API promised the reading was recorded and it was not"
    )


def test_an_intercepted_lab_value_is_actually_stored(client, user):
    resp = client.post(f"{API}/labs", headers=user["headers"], json={
        "profile_id": user["profile_id"], "fasting_glucose_mmol_l": 18.5,
    })
    assert resp.status_code == 409
    assert resp.json()["detail"]["recorded"] is True

    stored = client.get(f"{API}/vitals", headers=user["headers"],
                        params={"profile_id": user["profile_id"],
                                "type": "glucose"}).json()
    assert any(abs(r["value"] - 18.5) < 0.01 for r in stored)


def test_the_under_18_safety_event_survives_its_own_403(client):
    """PRD §14 measures the false-negative rate from safety_events rows.
    A row that is rolled back cannot be counted."""
    from sqlalchemy import text as sql_text

    resp = client.post(f"{API}/auth/signup", json={
        "email": f"minor{uuid.uuid4().hex[:10]}@example.com",
        "password": "correct horse battery staple",
        "display_name": "Minor", "region": "bd", "locale": "en",
        "accept_terms": True,
    })
    headers = _auth(resp.json())
    client.post(f"{API}/consents", json={"kind": "medical_disclaimer"},
                headers=headers)
    profile_id = client.get(f"{API}/profiles", headers=headers).json()[0]["id"]

    account_id = client.get(f"{API}/me", headers=headers).json()["id"]

    blocked = client.put(f"{API}/profiles/{profile_id}/health", headers=headers,
                         json={**HEALTH, "age_years": 15})
    assert blocked.status_code == 403
    assert blocked.json()["detail"]["safety_card"]["trigger"] == "under_18"

    # Read as the owning account. RLS denies everything to an unset actor, so
    # querying without one would report zero whether or not the row exists.
    with engine.connect() as conn:
        conn.execute(sql_text("SELECT set_config('app.account_id', :a, false)"),
                     {"a": account_id})
        count = conn.execute(sql_text(
            "SELECT count(*) FROM safety_events WHERE profile_id = :p "
            "AND trigger = 'under_18'"
        ), {"p": profile_id}).scalar()
    assert count == 1, "the safety event was rolled back with the 403"


def test_vitals_can_be_read_back(client, user):
    client.post(f"{API}/vitals", headers=user["headers"], json={
        "profile_id": user["profile_id"], "type": "glucose",
        "value": 5.4, "unit": "mmol/L", "context_tag": "fasting",
    })
    rows = client.get(f"{API}/vitals", headers=user["headers"],
                      params={"profile_id": user["profile_id"], "type": "glucose"}).json()
    assert rows and rows[0]["value"] == pytest.approx(5.4)


# ── coach ─────────────────────────────────────────────────────────────

def test_the_coach_deflects_medication_questions(client, user):
    out = client.post(f"{API}/coach/message", headers=user["headers"], json={
        "profile_id": user["profile_id"],
        "message": "should I stop taking my metformin?",
    }).json()
    assert out["intercepted"] is True
    assert "doctor" in out["reply"].lower()
    assert out["model_backed"] is False


def test_the_coach_refuses_the_diagnosis_question(client, user):
    out = client.post(f"{API}/coach/message", headers=user["headers"], json={
        "profile_id": user["profile_id"], "message": "do I have diabetes?",
    }).json()
    assert out["intercepted"] is True
    assert "blood test" in out["reply"].lower()


def test_a_red_flag_reaches_the_interceptor_before_the_responder(client, user):
    out = client.post(f"{API}/coach/message", headers=user["headers"], json={
        "profile_id": user["profile_id"],
        "message": "I have chest pain right now",
    }).json()
    assert out["safety_card"] is not None
    assert out["safety_card"]["severity"] == "emergency"
    assert out["safety_card"]["emergency_number"] == "999"


def test_a_safety_interception_is_never_rate_limited(client, user):
    """PRD §F16 forbids gating a safety message behind payment, and a daily
    cap is a gate. Burn the free allowance, then send an emergency."""
    for i in range(COACH_FREE_DAILY_LIMIT):
        client.post(f"{API}/coach/message", headers=user["headers"], json={
            "profile_id": user["profile_id"], "message": f"how are my steps {i}?"})

    capped = client.post(f"{API}/coach/message", headers=user["headers"], json={
        "profile_id": user["profile_id"], "message": "and my calories?"})
    assert capped.status_code == 402

    emergency = client.post(f"{API}/coach/message", headers=user["headers"], json={
        "profile_id": user["profile_id"], "message": "I have chest pain"})
    assert emergency.status_code == 200
    assert emergency.json()["safety_card"]["severity"] == "emergency"


def test_the_coach_never_invents_a_figure_it_does_not_have(client, user):
    out = client.post(f"{API}/coach/message", headers=user["headers"], json={
        "profile_id": user["profile_id"], "message": "how is my glucose doing?",
    }).json()
    # No reading logged for this fresh profile, so it must say so rather than
    # producing a number.
    assert "not logged" in out["reply"].lower() or "mmol/L" in out["reply"]


# ── insights and reports ──────────────────────────────────────────────

def test_insights_report_insufficient_data_rather_than_inventing_a_pattern(
        client, user):
    out = client.get(f"{API}/insights/weekly", headers=user["headers"],
                     params={"profile_id": user["profile_id"]}).json()
    assert out["minimum_observations"] >= 5
    if out["insufficient_data"]:
        assert out["insights"] == []


def test_every_insight_names_its_evidence(client, user):
    rice = client.get(f"{API}/foods", params={"q": "Boiled rice"},
                      headers=user["headers"]).json()[0]
    today = date.today()
    for offset in range(6):
        client.post(f"{API}/meals", headers=user["headers"], json={
            "profile_id": user["profile_id"], "slot": "lunch",
            "eaten_at": f"{today - timedelta(days=offset)}T12:00:00+00:00",
            "items": [{"food_id": rice["id"], "name": "Boiled rice",
                       "quantity": 1, "unit": "bowl"}],
        })

    out = client.get(f"{API}/insights/weekly", headers=user["headers"],
                     params={"profile_id": user["profile_id"]}).json()
    assert out["insights"], "six logged days should clear the minimum"
    for insight in out["insights"]:
        assert insight["observations"] >= 5
        # Never causal. The wording must not outrun a self-reported log.
        assert "causes" not in insight["detail"].lower()


def test_a_report_carries_the_basis_and_the_validation_status(client, user):
    client.post(f"{API}/risk/assess", headers=user["headers"],
                json={"profile_id": user["profile_id"]})
    report = client.post(f"{API}/reports/generate", headers=user["headers"],
                         json={"profile_id": user["profile_id"], "days": 28})
    assert report.status_code == 201, report.text
    payload = report.json()["payload"]

    assert payload["risk"]["validation_status"] == "not_validated"
    assert payload["risk"]["clinical_score"]
    # A range, never a point value — the same rule the risk screen holds.
    assert payload["risk"]["range_low"] < payload["risk"]["range_high"]
    assert "not a diagnosis" in payload["disclaimer"].lower()


def test_a_stored_report_is_returned_verbatim(client, user):
    created = client.post(f"{API}/reports/generate", headers=user["headers"],
                          json={"profile_id": user["profile_id"], "days": 7}).json()
    fetched = client.get(f"{API}/reports/{created['id']}",
                         headers=user["headers"]).json()
    assert fetched["payload"] == created["payload"]


# ── billing ───────────────────────────────────────────────────────────

def test_the_free_forever_list_is_in_the_payload(client, user):
    out = client.get(f"{API}/billing/plans", headers=user["headers"]).json()
    free = " ".join(out["free_forever"]).lower()
    assert "risk assessment" in free
    assert "safety" in free
    assert "export" in free
    assert out["current_status"] == "free"


def test_subscribing_starts_a_trial_and_lifts_the_coach_cap(client, user):
    client.post(f"{API}/billing/subscribe", headers=user["headers"],
                json={"plan_code": "monthly"})
    me = client.get(f"{API}/me", headers=user["headers"]).json()
    assert me["subscription_status"] == "trial"

    for i in range(COACH_FREE_DAILY_LIMIT + 2):
        resp = client.post(f"{API}/coach/message", headers=user["headers"], json={
            "profile_id": user["profile_id"], "message": f"how are my steps {i}?"})
        assert resp.status_code == 200
        assert resp.json()["questions_remaining"] is None


# ── account ───────────────────────────────────────────────────────────

def test_export_returns_everything_and_is_free(client, user):
    out = client.post(f"{API}/me/export", headers=user["headers"])
    assert out.status_code == 200
    body = out.json()
    for section in ("account", "profiles", "consents", "health_profiles",
                    "risk_assessments", "vitals", "meals", "checkins", "activity"):
        assert section in body


def test_deleting_an_account_requires_typing_the_email(client, user):
    me = client.get(f"{API}/me", headers=user["headers"]).json()
    wrong = client.delete(f"{API}/me", headers=user["headers"],
                          params={"confirm_email": "not-my-email@example.com"})
    assert wrong.status_code == 400

    right = client.delete(f"{API}/me", headers=user["headers"],
                          params={"confirm_email": me["email"]})
    assert right.status_code == 204


# ── the disclaimer gate still covers everything new ───────────────────

def test_every_new_health_endpoint_is_behind_the_disclaimer(client):
    """A client that skips the blocking screen must be refused here too."""
    resp = client.post(f"{API}/auth/signup", json={
        "email": f"g{uuid.uuid4().hex[:12]}@example.com",
        "password": "correct horse battery staple",
        "display_name": "No Disclaimer", "accept_terms": True,
    })
    headers = _auth(resp.json())
    profile_id = client.get(f"{API}/profiles", headers=headers).json()[0]["id"]

    gated = [
        ("post", f"{API}/meals",
         {"profile_id": profile_id, "slot": "lunch",
          "items": [{"name": "Rice", "quantity": 1, "unit": "bowl"}]}),
        ("post", f"{API}/checkins", {"profile_id": profile_id, "energy": 3}),
        ("post", f"{API}/activity", {"profile_id": profile_id, "steps": 100}),
        ("post", f"{API}/coach/message",
         {"profile_id": profile_id, "message": "hello"}),
        ("post", f"{API}/reports/generate", {"profile_id": profile_id}),
    ]
    for method, url, body in gated:
        resp = getattr(client, method)(url, json=body, headers=headers)
        assert resp.status_code == 403, f"{url} was not gated"
        assert resp.json()["detail"]["reason"] == "medical_disclaimer_required"

    for url, params in [
        (f"{API}/plan/today", {"profile_id": profile_id}),
        (f"{API}/insights/weekly", {"profile_id": profile_id}),
    ]:
        resp = client.get(url, params=params, headers=headers)
        assert resp.status_code == 403, f"{url} was not gated"
