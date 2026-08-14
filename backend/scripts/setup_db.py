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

    url = (f"postgresql+psycopg://{settings.postgres_superuser}:{su_password}"
           f"@{settings.postgres_host}:{settings.postgres_port}/postgres")

    # AUTOCOMMIT because CREATE DATABASE cannot run inside a transaction block.
    engine = create_engine(url, isolation_level="AUTOCOMMIT")

    try:
        with engine.connect() as conn:
            version = conn.execute(text("SHOW server_version")).scalar()
            print(f"Connected to PostgreSQL {version} on port {settings.postgres_port}")

            if args.drop:
                print(f"Dropping database {settings.postgres_db} ...")
                conn.execute(text(
                    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
                    "WHERE datname = :db AND pid <> pg_backend_pid()"
                ), {"db": settings.postgres_db})
                conn.execute(text(f'DROP DATABASE IF EXISTS "{settings.postgres_db}"'))

            exists = conn.execute(
                text("SELECT 1 FROM pg_roles WHERE rolname = :r"),
                {"r": settings.postgres_user},
            ).scalar()
            if exists:
                conn.execute(text(
                    f'ALTER ROLE "{settings.postgres_user}" WITH LOGIN PASSWORD :pw '
                    f'NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS'
                ), {"pw": app_password})
                print(f"Role {settings.postgres_user} updated")
            else:
                conn.execute(text(
                    f'CREATE ROLE "{settings.postgres_user}" WITH LOGIN PASSWORD :pw '
                    f'NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS'
                ), {"pw": app_password})
                print(f"Role {settings.postgres_user} created (no superuser, no bypassrls)")

            db_exists = conn.execute(
                text("SELECT 1 FROM pg_database WHERE datname = :d"),
                {"d": settings.postgres_db},
            ).scalar()
            if db_exists:
                print(f"Database {settings.postgres_db} already exists")
            else:
                conn.execute(text(f'CREATE DATABASE "{settings.postgres_db}"'))
                print(f"Database {settings.postgres_db} created")
            conn.execute(text(
                f'ALTER DATABASE "{settings.postgres_db}" OWNER TO "{settings.postgres_user}"'))

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
