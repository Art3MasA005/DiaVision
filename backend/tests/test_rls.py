"""Adversarial cross-profile access tests. PRD §18, before multi-profile ships.

    "Adversarial test: attempt cross-profile read with a valid token for
     another profile -> must fail."

These run against a real PostgreSQL database because that is the only place the
guarantee actually lives. Mocking the database here would test nothing — the
policies are the feature.

Skipped automatically when no database is reachable, so the rest of the suite
still runs on a fresh checkout.
"""

from __future__ import annotations

import sys
import uuid
from pathlib import Path

import pytest
from sqlalchemy import select, text

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.auth import hash_password  # noqa: E402
from app.db.models import (  # noqa: E402
    Account, AccessAuditLog, HealthProfile, Profile, ProfileMembership,
    PROFILE_SCOPED_TABLES, RiskAssessment,
)
from app.db.session import SessionLocal, engine, set_actor  # noqa: E402


def _database_available() -> bool:
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return True
    except Exception:
        return False


pytestmark = pytest.mark.skipif(
    not _database_available(),
    reason="no database — run backend/scripts/setup_db.py and alembic upgrade head",
)


@pytest.fixture
def two_users():
    """Two unrelated accounts, each with their own profile and health record."""
    created: list[tuple] = []
    session = SessionLocal()
    try:
        # Bootstrap runs without an actor set. RLS still applies, so INSERTs
        # must satisfy the WITH CHECK clauses; accounts are inserted first with
        # the actor set to the new id.
        for tag in ("alice", "bob"):
            account_id = uuid.uuid4()
            set_actor(session, account_id)
            account = Account(
                id=account_id, email=f"{tag}-{account_id.hex[:8]}@test.local",
                password_hash=hash_password("correct horse battery"),
                home_region="bd",
            )
            session.add(account)
            session.flush()

            profile = Profile(
                account_id_owner=account_id, claimed_by_account_id=account_id,
                display_name=tag.title(), profile_type="self", region_pack="bd",
            )
            session.add(profile)
            session.flush()

            session.add(ProfileMembership(
                profile_id=profile.id, account_id=account_id,
                role="owner", scope="full", granted_by=account_id,
            ))
            session.add(HealthProfile(
                profile_id=profile.id, sex_at_birth="male", height_cm=172.0,
                weight_kg=82.0, waist_cm=102.0, family_history="first_degree",
                physical_activity="sedentary",
            ))
            session.commit()
            created.append((account_id, profile.id))

        yield created
    finally:
        # Cleanup needs to bypass RLS, so it runs as the owner of each profile.
        for account_id, profile_id in created:
            set_actor(session, account_id)
            session.query(Profile).filter(Profile.id == profile_id).delete()
            session.query(Account).filter(Account.id == account_id).delete()
            session.commit()
        session.close()


def test_the_app_role_is_not_a_superuser():
    """A superuser silently bypasses every policy below, voiding all of them."""
    with engine.connect() as conn:
        row = conn.execute(text(
            "SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user"
        )).one()
    assert not row[0], "application role must not be SUPERUSER"
    assert not row[1], "application role must not have BYPASSRLS"


def test_rls_is_enabled_and_forced_on_every_health_table():
    """A new table without a policy must fail here, not leak in production."""
    with engine.connect() as conn:
        rows = conn.execute(text(
            "SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class "
            "WHERE relname = ANY(:names) AND relkind = 'r'"
        ), {"names": PROFILE_SCOPED_TABLES}).all()

    seen = {r[0]: (r[1], r[2]) for r in rows}
    missing = set(PROFILE_SCOPED_TABLES) - set(seen)
    assert not missing, f"tables absent from the database: {missing}"
    for name, (enabled, forced) in seen.items():
        assert enabled, f"{name}: row-level security is not ENABLED"
        assert forced, f"{name}: row-level security is not FORCED (owner would bypass it)"


def test_alice_cannot_read_bobs_profile(two_users):
    """The core guarantee: a valid session for A cannot see B."""
    (alice, _), (_, bob_profile) = two_users
    session = SessionLocal()
    try:
        set_actor(session, alice)
        assert session.get(Profile, bob_profile) is None
    finally:
        session.close()


def test_alice_cannot_read_bobs_health_record(two_users):
    (alice, _), (_, bob_profile) = two_users
    session = SessionLocal()
    try:
        set_actor(session, alice)
        assert session.get(HealthProfile, bob_profile) is None
        assert session.scalars(select(HealthProfile)).all() == []
    finally:
        session.close()


def test_alice_cannot_write_to_bobs_profile(two_users):
    """Writes must fail too — a read-only guarantee is not enough."""
    (alice, _), (_, bob_profile) = two_users
    session = SessionLocal()
    try:
        set_actor(session, alice)
        session.add(RiskAssessment(
            profile_id=bob_profile, tier=1, inputs_json={}, risk_probability=0.5,
            risk_band="high", confidence_low=0.4, confidence_high=0.6,
            region="bd", validation_status="not_validated",
            clinical_score="IDRS", clinical_points=50, model_version="test",
        ))
        with pytest.raises(Exception):
            session.flush()
    finally:
        session.rollback()
        session.close()


def test_each_user_sees_exactly_their_own_profile(two_users):
    (alice, alice_profile), (bob, bob_profile) = two_users
    session = SessionLocal()
    try:
        set_actor(session, alice)
        assert [p.id for p in session.scalars(select(Profile))] == [alice_profile]
        session.rollback()

        set_actor(session, bob)
        assert [p.id for p in session.scalars(select(Profile))] == [bob_profile]
    finally:
        session.close()


def test_an_unset_actor_sees_nothing(two_users):
    """The default must be deny, not allow."""
    session = SessionLocal()
    try:
        set_actor(session, None)
        assert session.scalars(select(Profile)).all() == []
        assert session.scalars(select(HealthProfile)).all() == []
    finally:
        session.close()


def test_a_granted_viewer_can_read_but_not_write(two_users):
    """Scope 'view' is read-only — PRD §3.6 scoped grants."""
    (alice, _), (bob, bob_profile) = two_users
    session = SessionLocal()
    try:
        set_actor(session, bob)
        session.add(ProfileMembership(
            profile_id=bob_profile, account_id=alice, role="viewer",
            scope="view", granted_by=bob,
        ))
        session.commit()

        set_actor(session, alice)
        assert session.get(Profile, bob_profile) is not None, "grant should permit reading"

        session.add(RiskAssessment(
            profile_id=bob_profile, tier=1, inputs_json={}, risk_probability=0.5,
            risk_band="high", confidence_low=0.4, confidence_high=0.6,
            region="bd", validation_status="not_validated",
            clinical_score="IDRS", clinical_points=50, model_version="test",
        ))
        with pytest.raises(Exception):
            session.flush()
    finally:
        session.rollback()
        session.close()


def test_revocation_takes_effect_immediately(two_users):
    """PRD §3.6 — revocation is one tap and immediate, not eventually."""
    (alice, _), (bob, bob_profile) = two_users
    session = SessionLocal()
    try:
        set_actor(session, bob)
        grant = ProfileMembership(
            profile_id=bob_profile, account_id=alice, role="viewer",
            scope="view", granted_by=bob,
        )
        session.add(grant)
        session.commit()

        set_actor(session, alice)
        assert session.get(Profile, bob_profile) is not None
        session.rollback()

        set_actor(session, bob)
        session.execute(text(
            "UPDATE profile_memberships SET revoked_at = now() WHERE id = :i"
        ), {"i": grant.id})
        session.commit()

        set_actor(session, alice)
        session.expire_all()
        assert session.get(Profile, bob_profile) is None, "revoked grant still permits access"
    finally:
        session.rollback()
        session.close()


def test_the_audit_log_cannot_be_rewritten(two_users):
    """An audit trail the application can edit is not an audit trail."""
    (alice, alice_profile), _ = two_users
    session = SessionLocal()
    try:
        set_actor(session, alice)
        session.add(AccessAuditLog(
            profile_id=alice_profile, actor_account_id=alice, actor_role="viewer",
            action="read", resource="risk_assessment",
        ))
        session.commit()

        with pytest.raises(Exception):
            session.execute(text(
                "UPDATE access_audit_log SET action = 'tampered' WHERE profile_id = :p"
            ), {"p": alice_profile})
            session.flush()
        session.rollback()

        with pytest.raises(Exception):
            session.execute(text(
                "DELETE FROM access_audit_log WHERE profile_id = :p"
            ), {"p": alice_profile})
            session.flush()
    finally:
        session.rollback()
        session.close()
