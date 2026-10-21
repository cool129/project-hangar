import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def app_line(ts, message, level="INFO", **extra):
    return json.dumps(
        {
            "timestamp": ts,
            "level": level,
            "logger": "sortie_tracker",
            "message": message,
            "request_id": extra.pop("request_id", None),
            **extra,
        }
    )


def access(ts, route, status, ms=12.0, rid=None):
    return app_line(
        ts,
        "request",
        http_method="GET",
        route=route,
        path=route,
        status_code=status,
        duration_ms=ms,
        client_ip="10.244.0.7",
        request_id=rid,
    )


def gateway(ts, path, status, upstream="10.244.0.12:8000", rid=None):
    return json.dumps(
        {
            "start_time": ts,
            "method": "GET",
            "path": path,
            "status": status,
            "duration_ms": 5,
            "request_id": rid,
            "upstream": upstream,
            "client_ip": "203.0.113.9",
        }
    )


@pytest.fixture
def db_outage_lines():
    """Healthy traffic, then PostgreSQL becomes unreachable from the pods."""
    lines = []
    for i in range(40):  # 10:00-10:03 healthy
        ts = f"2026-10-21T10:0{i // 10}:{i % 10 * 5:02d}.000+00:00"
        lines.append(access(ts, "/api/v1/sorties", 200, rid=f"ok{i:030d}"))
        lines.append(gateway(ts, "/api/v1/sorties", 200, rid=f"ok{i:030d}"))
    for i in range(60):  # 10:05-10:10 outage
        ts = f"2026-10-21T10:{5 + i // 12:02d}:{i % 12 * 5:02d}.000+00:00"
        rid = f"bad{i:029d}"
        lines.append(
            app_line(
                ts,
                "database_unavailable",
                level="ERROR",
                request_id=rid,
                error_type="OperationalError",
                exception="psycopg.errors.ConnectionTimeout: connection to server at "
                '"10.10.8.4", port 5432 failed: timeout expired',
            )
        )
        lines.append(access(ts, "/api/v1/sorties/{sortie_id}", 503, ms=5003.0, rid=rid))
        lines.append(gateway(ts, f"/api/v1/sorties/{i}", 503, rid=rid))
        if i % 3 == 0:
            lines.append(
                app_line(
                    ts,
                    "readiness_check_failed",
                    level="WARNING",
                    error_type="OperationalError",
                    error="connection to 10.10.8.4 timed out after 5 s",
                )
            )
    lines.append("Traceback (most recent call last):")
    return lines
