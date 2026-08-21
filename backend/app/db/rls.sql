-- Row-level security. PRD §18: "enforced at the database layer, not just the API".
--
-- The threat this defends against is not a clever attacker. It is an ordinary
-- Tuesday six months from now when someone adds an endpoint and forgets a
-- WHERE clause. With RLS on, that endpoint returns nothing instead of
-- returning somebody else's glucose readings.
--
-- How it works:
--   * the app connects as byebye_app, a role WITHOUT superuser and WITHOUT
--     BYPASSRLS. A superuser silently ignores every policy below, which is
--     why the application must never connect as one.
--   * each request opens a transaction and issues
--       SET LOCAL app.account_id = '<uuid>';
--     SET LOCAL is scoped to the transaction, so a pooled connection cannot
--     leak one user's identity into the next request.
--   * every policy resolves visibility from that setting alone.
--
-- ── POLICIES MUST NOT FORM A CYCLE ───────────────────────────────────
--
-- A policy on table A that queries table B invokes B's policy. If B's policy
-- then queries A, neither can ever resolve — and PostgreSQL does not always
-- report this as an error. An earlier version of this file had `profiles_read`
-- call a helper that itself selected from `profiles`; the result was that the
-- profiles table was invisible to everyone including its own owner, and
-- INSERT ... RETURNING failed with a WITH CHECK violation.
--
-- The dependency graph below is a strict DAG, and must stay one:
--
--     health tables ─> app_can_read_profile() ─> profiles ─> profile_memberships
--                                                                  │
--                                                             (own columns only,
--                                                              terminates here)
--
-- profile_memberships carries a denormalised owner_account_id precisely so its
-- policies never need to look up `profiles`.

-- ── current actor ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION app_current_account() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.account_id', true), '')::uuid;
$$;

COMMENT ON FUNCTION app_current_account() IS
  'The account making this request. NULL when unset, which denies everything.';

-- ── accounts ─────────────────────────────────────────────────────────

ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE accounts FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS accounts_self ON accounts;
CREATE POLICY accounts_self ON accounts
  USING (id = app_current_account())
  WITH CHECK (id = app_current_account());

-- ── consents ─────────────────────────────────────────────────────────
-- Account-scoped, not profile-scoped, and append-only: a withdrawal writes a
-- new row rather than editing an old one, so the agreement history survives.

ALTER TABLE consents ENABLE ROW LEVEL SECURITY;
ALTER TABLE consents FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS consents_read ON consents;
CREATE POLICY consents_read ON consents FOR SELECT
  USING (account_id = app_current_account());

DROP POLICY IF EXISTS consents_append ON consents;
CREATE POLICY consents_append ON consents FOR INSERT
  WITH CHECK (account_id = app_current_account());

-- No UPDATE or DELETE policy: with FORCE RLS both are denied outright.
REVOKE UPDATE, DELETE ON consents FROM PUBLIC;

-- ── profile_memberships ──────────────────────────────────────────────
-- Defined FIRST because everything else depends on it, and it depends on
-- nothing. Own columns only — no subqueries, so this always terminates.

ALTER TABLE profile_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE profile_memberships FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS memberships_read ON profile_memberships;
CREATE POLICY memberships_read ON profile_memberships FOR SELECT
  USING (
    account_id = app_current_account()          -- grants made to me
    OR owner_account_id = app_current_account() -- grants on a profile I own
  );

-- Only the profile OWNER may grant or revoke. A viewer cannot re-share
-- someone else's health record.
DROP POLICY IF EXISTS memberships_write ON profile_memberships;
CREATE POLICY memberships_write ON profile_memberships FOR ALL
  USING (owner_account_id = app_current_account())
  WITH CHECK (owner_account_id = app_current_account());

-- Keep owner_account_id honest. It is security-relevant, so it is maintained
-- by the database rather than trusted from the application.
CREATE OR REPLACE FUNCTION app_sync_membership_owner() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  SELECT p.account_id_owner INTO NEW.owner_account_id
  FROM profiles p WHERE p.id = NEW.profile_id;
  IF NEW.owner_account_id IS NULL THEN
    RAISE EXCEPTION 'profile % does not exist', NEW.profile_id;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_membership_owner ON profile_memberships;
CREATE TRIGGER trg_membership_owner
  BEFORE INSERT OR UPDATE OF profile_id ON profile_memberships
  FOR EACH ROW EXECUTE FUNCTION app_sync_membership_owner();

-- If a profile changes hands, every membership must follow.
CREATE OR REPLACE FUNCTION app_cascade_profile_owner() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  IF NEW.account_id_owner IS DISTINCT FROM OLD.account_id_owner THEN
    UPDATE profile_memberships SET owner_account_id = NEW.account_id_owner
    WHERE profile_id = NEW.id;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_profile_owner_cascade ON profiles;
CREATE TRIGGER trg_profile_owner_cascade
  AFTER UPDATE OF account_id_owner ON profiles
  FOR EACH ROW EXECUTE FUNCTION app_cascade_profile_owner();

-- ── profiles ─────────────────────────────────────────────────────────
-- Inline conditions, NOT a helper that re-queries this table. The only
-- subquery is against profile_memberships, which terminates above.

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS profiles_read ON profiles;
CREATE POLICY profiles_read ON profiles FOR SELECT
  USING (
    account_id_owner = app_current_account()
    OR claimed_by_account_id = app_current_account()
    OR EXISTS (
      SELECT 1 FROM profile_memberships m
      WHERE m.profile_id = profiles.id
        AND m.account_id = app_current_account()
        AND m.revoked_at IS NULL
        -- Revocation is immediate (PRD §3.6), and expiry is enforced here
        -- rather than by a cleanup job, so a lapsed grant stops working the
        -- moment it lapses.
        AND (m.expires_at IS NULL OR m.expires_at > now())
    )
  );

DROP POLICY IF EXISTS profiles_insert ON profiles;
CREATE POLICY profiles_insert ON profiles FOR INSERT
  WITH CHECK (account_id_owner = app_current_account());

DROP POLICY IF EXISTS profiles_update ON profiles;
CREATE POLICY profiles_update ON profiles FOR UPDATE
  USING (
    account_id_owner = app_current_account()
    OR claimed_by_account_id = app_current_account()
    OR EXISTS (
      SELECT 1 FROM profile_memberships m
      WHERE m.profile_id = profiles.id
        AND m.account_id = app_current_account()
        AND m.revoked_at IS NULL
        AND (m.expires_at IS NULL OR m.expires_at > now())
        AND m.scope IN ('view_targets', 'full')   -- 'view' is read-only
    )
  )
  WITH CHECK (account_id_owner = app_current_account()
              OR claimed_by_account_id = app_current_account());

DROP POLICY IF EXISTS profiles_delete ON profiles;
CREATE POLICY profiles_delete ON profiles FOR DELETE
  USING (account_id_owner = app_current_account());

-- ── access helpers for the health tables ─────────────────────────────
-- These query `profiles` and are used ONLY by tables that `profiles` does not
-- query back, so the graph stays acyclic.

CREATE OR REPLACE FUNCTION app_can_read_profile(target uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM profiles p WHERE p.id = target AND p.archived_at IS NULL);
$$;

COMMENT ON FUNCTION app_can_read_profile(uuid) IS
  'True when the current account can see this profile. Relies on the profiles '
  'RLS policy doing the filtering, so it must never be used in a policy ON profiles.';

CREATE OR REPLACE FUNCTION app_can_write_profile(target uuid) RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM profiles p
    WHERE p.id = target
      AND p.archived_at IS NULL
      AND (
        p.account_id_owner = app_current_account()
        OR p.claimed_by_account_id = app_current_account()
        OR EXISTS (
          SELECT 1 FROM profile_memberships m
          WHERE m.profile_id = p.id
            AND m.account_id = app_current_account()
            AND m.revoked_at IS NULL
            AND (m.expires_at IS NULL OR m.expires_at > now())
            AND m.scope IN ('view_targets', 'full')
        )
      )
  );
$$;

-- ── health tables ────────────────────────────────────────────────────

-- Every table below carries a profile_id column directly, including
-- meal_log_items — which denormalises it precisely so its policy reads its own
-- column instead of joining meal_logs and inheriting that table's policy.

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY[
    'health_profiles', 'risk_assessments', 'vital_logs', 'safety_events',
    'meal_logs', 'meal_log_items', 'daily_checkins', 'activity_logs',
    'coach_messages', 'reports'
  ]
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);

    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', t || '_read', t);
    EXECUTE format(
      'CREATE POLICY %I ON %I FOR SELECT USING (app_can_read_profile(profile_id))',
      t || '_read', t);

    EXECUTE format('DROP POLICY IF EXISTS %I ON %I', t || '_write', t);
    EXECUTE format(
      'CREATE POLICY %I ON %I FOR ALL USING (app_can_write_profile(profile_id)) '
      'WITH CHECK (app_can_write_profile(profile_id))',
      t || '_write', t);
  END LOOP;
END $$;

-- ── food_items: reference data, deliberately not RLS-protected ───────
-- It has no profile_id and contains nobody's health information — it is a
-- composition table, the same for every user. Enabling FORCE RLS here would
-- only mean the seeder could not write it either. The API exposes no write
-- path to this table; that is where the restriction lives.

REVOKE INSERT, UPDATE, DELETE ON food_items FROM PUBLIC;

-- ── audit log: append-only ───────────────────────────────────────────
-- Deliberately NOT covered by the loop above. An audit trail the application
-- can UPDATE or DELETE is not an audit trail.

ALTER TABLE access_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE access_audit_log FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS audit_read ON access_audit_log;
CREATE POLICY audit_read ON access_audit_log FOR SELECT
  USING (app_can_read_profile(profile_id) AND visible_to_patient);

DROP POLICY IF EXISTS audit_append ON access_audit_log;
CREATE POLICY audit_append ON access_audit_log FOR INSERT
  WITH CHECK (app_can_read_profile(profile_id));

-- No UPDATE or DELETE policy exists, so with FORCE RLS both are denied
-- outright for every non-superuser role.

REVOKE UPDATE, DELETE ON access_audit_log FROM PUBLIC;
