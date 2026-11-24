"""FastAPI application entrypoint.

    uvicorn app.main:app --reload --app-dir backend
"""

from __future__ import annotations

import logging

from fastapi import FastAPI, Request, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.api.password_reset import router as password_reset_router
from app.api.routes import router
from app.config import get_settings

settings = get_settings()
logging.basicConfig(level=settings.log_level)
log = logging.getLogger("byebye")

DESCRIPTION = """
Diabetes risk and lifestyle companion — backend API.

**This service never diagnoses.** It returns calibrated risk *estimates* with
explicit ranges, and every risk response carries a disclaimer. See
`/regions/{code}/validation` for whether the model is validated in a given
market; where it is not, the API falls back to a published clinical score and
says so in the response.
"""

app = FastAPI(
    title="DiaVision API",
    description=DESCRIPTION,
    version="0.1.0",
    docs_url="/docs",
)

# Tightened per environment before any real deployment.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"] if not settings.is_production else [],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(router, prefix="/api/v1")
app.include_router(password_reset_router, prefix="/api/v1")


@app.exception_handler(ValueError)
async def value_error_handler(_request: Request, exc: ValueError):
    return JSONResponse(status_code=status.HTTP_400_BAD_REQUEST, content={"detail": str(exc)})


@app.get("/health", tags=["ops"])
def health():
    """Liveness probe. Deliberately does not touch the database."""
    return {"status": "ok", "environment": settings.environment}


@app.get("/ready", tags=["ops"])
def ready():
    """Readiness probe — verifies the database and the model bundle."""
    from sqlalchemy import text

    from app.db.session import engine

    checks: dict[str, str] = {}
    try:
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        checks["database"] = "ok"
    except Exception as exc:
        checks["database"] = f"error: {type(exc).__name__}"

    try:
        import sys
        from pathlib import Path
        sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ml"))
        from pipelines.predict import load_model
        checks["model"] = "ok" if load_model("v1") else "missing bundle (clinical score only)"
    except Exception as exc:
        checks["model"] = f"error: {type(exc).__name__}"

    healthy = checks.get("database") == "ok"
    return JSONResponse(
        status_code=status.HTTP_200_OK if healthy else status.HTTP_503_SERVICE_UNAVAILABLE,
        content={"status": "ready" if healthy else "degraded", "checks": checks},
    )
