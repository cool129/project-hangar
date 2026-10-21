"""Application factory, request middleware and error handling."""

import logging
import time
import uuid

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from sqlalchemy.exc import IntegrityError, OperationalError, SQLAlchemyError

from sortie_tracker import __version__, metrics
from sortie_tracker.config import Settings, get_settings
from sortie_tracker.db import build_engine, build_session_factory
from sortie_tracker.logging_config import configure_logging, request_id_ctx
from sortie_tracker.routes import aircraft, health, sorties
from sortie_tracker.services import BusinessRuleViolation, NotFoundError

logger = logging.getLogger("sortie_tracker")

# Probe and scrape traffic is high-volume and uninteresting in access logs.
QUIET_ROUTES = {"/healthz", "/readyz", "/metrics"}


def _route_template(request: Request) -> str:
    route = request.scope.get("route")
    return getattr(route, "path", "unmatched")


def _error(
    request: Request, status_code: int, detail: str, rule: str | None = None
) -> JSONResponse:
    request_id = getattr(request.state, "request_id", None)
    return JSONResponse(
        {"detail": detail, "rule": rule, "request_id": request_id},
        status_code=status_code,
        headers={"X-Request-ID": request_id} if request_id else None,
    )


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    configure_logging(settings.log_level)

    app = FastAPI(
        title="Sortie Tracker",
        version=__version__,
        description="Aircraft mission-capable status and sortie lifecycle API.",
    )
    app.state.settings = settings
    app.state.engine = build_engine(settings)
    app.state.session_factory = build_session_factory(app.state.engine)

    app.include_router(health.router)
    app.include_router(aircraft.router)
    app.include_router(sorties.router)

    # A plain route, not app.mount(): a mount answers /metrics with a 307 to /metrics/.
    @app.get("/metrics", include_in_schema=False)
    def prometheus_metrics() -> Response:
        return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

    @app.middleware("http")
    async def request_context(request: Request, call_next):
        request_id = request.headers.get("x-request-id") or uuid.uuid4().hex
        request.state.request_id = request_id
        token = request_id_ctx.set(request_id)
        method = request.method
        status_code = 500
        start = time.perf_counter()
        metrics.HTTP_IN_PROGRESS.labels(method=method).inc()
        try:
            response = await call_next(request)
            status_code = response.status_code
            response.headers["X-Request-ID"] = request_id
            return response
        finally:
            duration = time.perf_counter() - start
            route = _route_template(request)
            metrics.HTTP_IN_PROGRESS.labels(method=method).dec()
            metrics.HTTP_REQUESTS.labels(method=method, route=route, status=str(status_code)).inc()
            metrics.HTTP_LATENCY.labels(method=method, route=route).observe(duration)
            if route not in QUIET_ROUTES:
                logger.info(
                    "request",
                    extra={
                        "http_method": method,
                        "route": route,
                        "path": request.url.path,
                        "status_code": status_code,
                        "duration_ms": round(duration * 1000, 2),
                        "client_ip": request.client.host if request.client else None,
                    },
                )
            request_id_ctx.reset(token)

    @app.exception_handler(NotFoundError)
    async def not_found(request: Request, exc: NotFoundError) -> JSONResponse:
        return _error(request, 404, str(exc))

    @app.exception_handler(BusinessRuleViolation)
    async def rule_violation(request: Request, exc: BusinessRuleViolation) -> JSONResponse:
        metrics.BUSINESS_RULE_VIOLATIONS.labels(rule=exc.rule).inc()
        logger.warning("business_rule_violation", extra={"rule": exc.rule, "detail": exc.detail})
        return _error(request, exc.status_code, exc.detail, rule=exc.rule)

    @app.exception_handler(IntegrityError)
    async def integrity_error(request: Request, exc: IntegrityError) -> JSONResponse:
        logger.warning("integrity_error", extra={"error": str(exc.orig)})
        return _error(
            request, 409, "Resource conflicts with existing data", rule="unique_constraint"
        )

    @app.exception_handler(OperationalError)
    async def database_unavailable(request: Request, exc: OperationalError) -> JSONResponse:
        metrics.DB_ERRORS.labels(error_type=type(exc.orig).__name__).inc()
        logger.error(
            "database_unavailable",
            exc_info=exc,
            extra={"request_id": getattr(request.state, "request_id", None)},
        )
        return _error(request, 503, "Database unavailable")

    @app.exception_handler(SQLAlchemyError)
    async def database_error(request: Request, exc: SQLAlchemyError) -> JSONResponse:
        metrics.DB_ERRORS.labels(error_type=type(exc).__name__).inc()
        logger.error(
            "database_error",
            exc_info=exc,
            extra={"request_id": getattr(request.state, "request_id", None)},
        )
        return _error(request, 500, "Internal database error")

    @app.exception_handler(Exception)
    async def unhandled(request: Request, exc: Exception) -> JSONResponse:
        # Runs outside the middleware's context, so pass the request ID explicitly.
        logger.error(
            "unhandled_exception",
            exc_info=exc,
            extra={"request_id": getattr(request.state, "request_id", None)},
        )
        return _error(request, 500, "Internal server error")

    logger.info(
        "app_started",
        extra={"version": __version__, "commit": settings.git_sha, "environment": settings.app_env},
    )
    return app


app = create_app()
