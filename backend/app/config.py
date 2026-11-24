"""Application settings, loaded from backend/.env."""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict

BACKEND_ROOT = Path(__file__).resolve().parents[1]
REPO_ROOT = BACKEND_ROOT.parent


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=BACKEND_ROOT / ".env", env_file_encoding="utf-8", extra="ignore"
    )

    # ── database ─────────────────────────────────────────
    postgres_host: str = "localhost"
    postgres_port: int = 5432
    postgres_db: str = "byebye_dev"
    postgres_user: str = "byebye_app"
    postgres_password: str = "change-me"

    postgres_superuser: str = "postgres"
    postgres_superuser_password: str = ""

    # ── auth ─────────────────────────────────────────────
    jwt_secret: str = "change-me-in-production"
    jwt_algorithm: str = "HS256"
    access_token_minutes: int = 30
    refresh_token_days: int = 30

    # ── language model (OpenRouter) ──────────────────────
    # Empty key = no model. The coach then falls back to its fixed-wording
    # answers and the camera to manual entry, and both say so.
    openrouter_api_key: str = ""
    openrouter_model: str = "qwen/qwen3.7-flash"
    openrouter_base_url: str = "https://openrouter.ai/api/v1"
    llm_timeout_seconds: float = 45.0

    # ── email (password reset codes) ─────────────────────
    # Empty host = no email. In development the code is then written to the
    # server log instead; in production reset answers 503 for every address
    # alike, rather than pretending a code was sent.
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_user: str = ""
    smtp_password: str = ""
    smtp_from: str = ""
    smtp_starttls: bool = True

    # ── app ──────────────────────────────────────────────
    environment: str = "development"
    default_region: str = "bd"
    log_level: str = "INFO"

    @property
    def database_url(self) -> str:
        """Application connection. Never a superuser — see .env.example."""
        return (
            f"postgresql+psycopg://{self.postgres_user}:{self.postgres_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{self.postgres_db}"
        )

    def superuser_url(self, database: str = "postgres") -> str:
        """Setup-only connection, used by scripts/setup_db.py."""
        return (
            f"postgresql+psycopg://{self.postgres_superuser}:{self.postgres_superuser_password}"
            f"@{self.postgres_host}:{self.postgres_port}/{database}"
        )

    @property
    def is_production(self) -> bool:
        return self.environment.lower() in ("production", "prod")


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
