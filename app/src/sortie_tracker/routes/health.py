"""Kubernetes probes.

/healthz (liveness) never touches the database: a DB outage must not make
Kubernetes restart every pod. /readyz (readiness) does, so pods that cannot
reach PostgreSQL are taken out of the Service until it recovers.
"""

import logging

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from sortie_tracker import __version__

router = APIRouter(tags=["health"])
logger = logging.getLogger(__name__)


@router.get("/healthz")
def liveness(request: Request) -> dict[str, str]:
    settings = request.app.state.settings
    return {
        "status": "ok",
        "version": __version__,
        "commit": settings.git_sha,
        "environment": settings.app_env,
    }


@router.get("/readyz")
def readiness(request: Request) -> JSONResponse:
    try:
        with request.app.state.engine.connect() as conn:
            conn.execute(text("SELECT 1"))
    except SQLAlchemyError as exc:
        logger.warning(
            "readiness_check_failed", extra={"error_type": type(exc).__name__, "error": str(exc)}
        )
        return JSONResponse({"status": "unavailable", "database": "unreachable"}, status_code=503)
    return JSONResponse({"status": "ready", "database": "ok"})
