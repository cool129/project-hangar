import json
import logging
import sys

from sqlalchemy import create_engine

from sortie_tracker.logging_config import JsonFormatter, request_id_ctx


def test_liveness_reports_version_and_commit(client):
    response = client.get("/healthz")
    assert response.status_code == 200
    assert response.json() == {
        "status": "ok",
        "version": "0.1.0",
        "commit": "abc123",
        "environment": "test",
    }


def test_readiness_ok_when_database_reachable(client):
    response = client.get("/readyz")
    assert response.status_code == 200
    assert response.json()["database"] == "ok"


def test_readiness_503_when_database_unreachable(app, client, monkeypatch):
    unreachable = create_engine("postgresql+psycopg://nobody@127.0.0.1:1/none?connect_timeout=1")
    monkeypatch.setattr(app.state, "engine", unreachable)
    response = client.get("/readyz")
    assert response.status_code == 503
    assert response.json()["database"] == "unreachable"


def test_request_id_is_generated_and_echoed(client):
    generated = client.get("/healthz").headers["X-Request-ID"]
    assert len(generated) == 32

    supplied = client.get("/healthz", headers={"X-Request-ID": "trace-me-123"})
    assert supplied.headers["X-Request-ID"] == "trace-me-123"


def test_metrics_use_route_templates_not_raw_paths(client, make_aircraft):
    aircraft = make_aircraft()
    client.get(f"/api/v1/aircraft/{aircraft['id']}")

    response = client.get("/metrics", follow_redirects=False)
    assert response.status_code == 200  # Prometheus scrapes this exact path
    assert response.headers["content-type"].startswith("text/plain")
    body = response.text
    assert 'route="/api/v1/aircraft/{aircraft_id}"' in body
    assert f'route="/api/v1/aircraft/{aircraft["id"]}"' not in body
    assert "http_request_duration_seconds_bucket" in body


def test_unhandled_exception_returns_500_with_request_id(app, client):
    @app.get("/boom")
    def boom():
        raise RuntimeError("kaboom")

    response = client.get("/boom", headers={"X-Request-ID": "req-500"})
    assert response.status_code == 500
    assert response.json() == {
        "detail": "Internal server error",
        "rule": None,
        "request_id": "req-500",
    }
    assert response.headers["X-Request-ID"] == "req-500"


def test_json_formatter_includes_request_id_extras_and_exception():
    token = request_id_ctx.set("req-42")
    try:
        try:
            raise ValueError("bad value")
        except ValueError:
            record = logging.getLogger("test").makeRecord(
                "test",
                logging.ERROR,
                __file__,
                1,
                "something failed",
                None,
                exc_info=sys.exc_info(),
                extra={"rule": "demo"},
            )
        line = json.loads(JsonFormatter().format(record))
    finally:
        request_id_ctx.reset(token)

    assert line["message"] == "something failed"
    assert line["level"] == "ERROR"
    assert line["request_id"] == "req-42"
    assert line["rule"] == "demo"
    assert line["error_type"] == "ValueError"
    assert "bad value" in line["exception"]
