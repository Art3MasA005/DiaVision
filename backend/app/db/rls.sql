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
--     SET LOCAL scopes it to the transaction, so a pooled connection cannot
--     leak one user's identity into the next request.
--   * every policy resolves visibility from that setting alone.
--
-- Applied by alembic (see the initial migration), not by hand.

-- ── current actor ────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION app_current_account() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT NULLIF(current_setting('app.account_id', true), '')::uuid;
$$;

COMMENT ON FUNCTION app_current_account() IS
  'The account making this request. NULL when unset, which denies everything.';

-- ── which profiles may this account touch, and how ───────────────────

CREATE OR REPLACE FUNCTION app_can_read_profile(target uuid) RETURNS boolean
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
            -- Revocation is immediate (PRD §3.6) and expiry is enforced here
            -- rather than by a cleanup job, so a lapsed grant stops working
            -- the moment it lapses.
            AND (m.expires_at IS NULL OR m.expires_at > now())
        )
      )
  );
$$;

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
            -- 'view' grants read only. A viewer must never write.
            AND m.scope IN ('view_targets', 'full')
        )
      )
  );
$$;

-- ── accounts ─────────────────────────────────────────────────────────

ALTER TABLE accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE accounts FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS accounts_self ON accounts;
CREATE POLICY accounts_self ON accounts
  USING (id = app_current_account())
  WITH CHECK (id = app_current_account());

-- ── profiles ─────────────────────────────────────────────────────────

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS profiles_read ON profiles;
CREATE POLICY profiles_read ON profiles FOR SELECT
  USING (app_can_read_profile(id));

DROP POLICY IF EXISTS profiles_insert ON profiles;
CREATE POLICY profiles_insert ON profiles FOR INSERT
  WITH CHECK (account_id_owner = app_current_account());

DROP POLICY IF EXISTS profiles_update ON profiles;
CREATE POLICY profiles_update ON profiles FOR UPDATE
  USING (app_can_write_profile(id))
  WITH CHECK (app_can_write_profile(id));

DROP POLICY IF EXISTS profiles_delete ON profiles;
CREATE POLICY profiles_delete ON profiles FOR DELETE
  USING (account_id_owner = app_current_account());

-- ── memberships ──────────────────────────────────────────────────────
-- Readable by the grantee and by anyone who can already see the profile, so a
-- patient can always answer "who can see my data?" (PRD §3.6).

ALTER TABLE profile_memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE profile_memberships FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS memberships_read ON profile_memberships;
CREATE POLICY memberships_read ON profile_memberships FOR SELECT
  USING (account_id = app_current_account() OR app_can_read_profile(profile_id));

-- Only an OWNER may grant or revoke access to a profile. A viewer cannot
-- re-share someone else's health record.
DROP POLICY IF EXISTS memberships_write ON profile_memberships;
CREATE POLICY memberships_write ON profile_memberships FOR ALL
  USING (EXISTS (SELECT 1 FROM profiles p
                 WHERE p.id = profile_id AND p.account_id_owner = app_current_account()))
  WITH CHECK (EXISTS (SELECT 1 FROM profiles p
                      WHERE p.id = profile_id AND p.account_id_owner = app_current_account()));

-- ── health tables ────────────────────────────────────────────────────
-- Same shape for each: read if you can read the profile, write if you can
-- write it. Kept as an explicit loop so adding a table without a policy is a
-- visible omission rather than a silent one.

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['health_profiles', 'risk_assessments', 'vital_logs', 'safety_events']
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

-- ── audit log: append-only ───────────────────────────────────────────
-- Deliberately NOT covered by the loop above. An audit trail that the
-- application can UPDATE or DELETE is not an audit trail.

ALTER TABLE access_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE access_audit_log FORCE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS audit_read ON access_audit_log;
CREATE POLICY audit_read ON access_audit_log FOR SELECT
  USING (app_can_read_profile(profile_id) AND visible_to_patient);

DROP POLICY IF EXISTS audit_append ON access_audit_log;
CREATE POLICY audit_append ON access_audit_log FOR INSERT
  WITH CHECK (true);

-- No UPDATE or DELETE policy exists, so with FORCE RLS both are denied
-- outright for every non-superuser role.

REVOKE UPDATE, DELETE ON access_audit_log FROM PUBLIC;
