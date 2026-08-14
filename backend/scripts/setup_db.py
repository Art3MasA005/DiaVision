"""Create the development database and the application role. Run once.

The application role is deliberately NOT a superuser and NOT BYPASSRLS,
because either of those silently disables every row-level security policy —
producing a system where the isolation tests pass and the isolation does not
exist.

Usage:
    python backend/scripts/setup_db.py --superuser-password "<your postgres password>"

or set POSTGRES_SUPERUSER_PASSWORD in backend/.env and run with no arguments.
"""

from __future__ import annotations

import argparse
import secrets
import sys
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BACKEND_ROOT))

import psycopg  # noqa: E402
from psycopg import sql  # noqa: E402
from sqlalchemy import create_engine, text  # noqa: E402

from app.config import get_settings  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--superuser-password", default=None,
                        help="password for the postgres superuser (set at install time)")
    parser.add_argument("--app-password", default=None,
                        help="password for the byebye_app role (generated if omitted)")
    parser.add_argument("--drop", action="store_true",
                        help="DROP the database first. Destroys all local data.")
    args = parser.parse_args()

    settings = get_settings()
    su_password = args.superuser_password or settings.postgres_superuser_password
    if not su_password:
        print("No superuser password. Pass --superuser-password or set")
        print("POSTGRES_SUPERUSER_PASSWORD in backend/.env")
        return 1

    app_password = args.app_password or settings.postgres_password
    if not app_password or app_password == "change-me":
        app_password = secrets.token_urlsafe(24)
        print(f"Generated a password for {settings.postgres_user}:\n    {app_password}")
        print("  -> put this in backend/.env as POSTGRES_PASSWORD\n")

    dsn = (f"host={settings.postgres_host} port={settings.postgres_port} "
           f"dbname=postgres user={settings.postgres_superuser} password={su_password}")

    role = sql.Identifier(settings.postgres_user)
    database = sql.Identifier(settings.postgres_db)
    # PostgreSQL DDL cannot take bind parameters, so the password is composed
    # as a literal. psycopg.sql.Literal quotes and escapes it properly —
    # never build this with an f-string.
    pw_literal = sql.Literal(app_password)

    try:
        # autocommit because CREATE DATABASE cannot run inside a transaction.
        with psycopg.connect(dsn, autocommit=True) as conn:
            version = conn.execute("SHOW server_version").fetchone()[0]
            print(f"Connected to PostgreSQL {version} on port {settings.postgres_port}")

            if args.drop:
                print(f"Dropping database {settings.postgres_db} ...")
                conn.execute(
                    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                    "WHERE datname = %s AND pid <> pg_backend_pid()",
                    (settings.postgres_db,),
                )
                conn.execute(sql.SQL("DROP DATABASE IF EXISTS {}").format(database))

            exists = conn.execute(
                "SELECT 1 FROM pg_roles WHERE rolname = %s", (settings.postgres_user,)
            ).fetchone()

            verb = "ALTER" if exists else "CREATE"
            conn.execute(sql.SQL(
                "{} ROLE {} WITH LOGIN PASSWORD {} "
                "NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS"
            ).format(sql.SQL(verb), role, pw_literal))
            print(f"Role {settings.postgres_user} "
                  f"{'updated' if exists else 'created'} (no superuser, no bypassrls)")

            db_exists = conn.execute(
                "SELECT 1 FROM pg_database WHERE datname = %s", (settings.postgres_db,)
            ).fetchone()
            if db_exists:
                print(f"Database {settings.postgres_db} already exists")
            else:
                conn.execute(sql.SQL("CREATE DATABASE {}").format(database))
                print(f"Database {settings.postgres_db} created")
            conn.execute(sql.SQL("ALTER DATABASE {} OWNER TO {}").format(database, role))

        # Extensions must be created inside the target database.
        target = create_engine(
            f"postgresql+psycopg://{settings.postgres_superuser}:{su_password}"
            f"@{settings.postgres_host}:{settings.postgres_port}/{settings.postgres_db}",
            isolation_level="AUTOCOMMIT",
        )
        with target.connect() as conn:
            conn.execute(text('CREATE EXTENSION IF NOT EXISTS "pgcrypto"'))
            conn.execute(text(f'GRANT ALL ON SCHEMA public TO "{settings.postgres_user}"'))
            print("Extensions and schema grants applied")

            # Login has a bootstrapping problem: RLS on `accounts` resolves
            # visibility from app.account_id, but at login we only have an
            # email and do not yet know the id. This function is the single
            # narrow exception — SECURITY DEFINER, owned by the superuser, so
            # it bypasses RLS.
            #
            # It returns three columns for one email and nothing else: no
            # billing data, no profile links, and no way to enumerate. Written
            # in plpgsql because plpgsql bodies are not parsed until first call,
            # so this can be created before the table exists.
            conn.execute(text("""
                CREATE OR REPLACE FUNCTION app_lookup_account_for_auth(p_email text)
                RETURNS TABLE (account_id uuid, password_hash text, deleted_at timestamptz)
                LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $fn$
                BEGIN
                  -- password_hash is varchar(255); RETURN QUERY demands an
                  -- exact type match against the declared TABLE(...) columns.
                  RETURN QUERY
                    SELECT a.id, a.password_hash::text, a.deleted_at
                    FROM accounts a WHERE a.email = p_email;
                END $fn$;
            """))
            conn.execute(text("REVOKE ALL ON FUNCTION app_lookup_account_for_auth(text) FROM PUBLIC"))
            conn.execute(text(
                f'GRANT EXECUTE ON FUNCTION app_lookup_account_for_auth(text) '
                f'TO "{settings.postgres_user}"'))
            print("Auth lookup function created (SECURITY DEFINER, superuser-owned)")

    except Exception as exc:
        print(f"\nFailed: {exc}")
        print("\nIf this is an authentication error, the superuser password is wrong.")
        print("It was set when you installed PostgreSQL.")
        return 1

    print("\nDone. Next:")
    print("    alembic -c backend/alembic.ini upgrade head")
    return 0


if __name__ == "__main__":
    sys.exit(main())
