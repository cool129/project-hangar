import pytest

from conftest import access, app_line, gateway
from log_analyzer import analyze, normalize, parse_lines, render_text, trace


def test_db_outage_is_diagnosed_with_runbook(db_outage_lines):
    report = analyze(parse_lines(db_outage_lines))

    assert report.totals["requests"] == 100
    assert report.totals["error_5xx"] == 60
    assert report.totals["error_ratio"] == 0.6

    titles = [f["title"] for f in report.findings]
    assert titles[0].startswith("5xx ratio 60.0% exceeds the 1% SLO budget (60x burn)")
    db = next(
        f for f in report.findings if f["title"] == "PostgreSQL unreachable from the API pods"
    )
    assert db["severity"] == "critical"
    assert db["runbook"] == "docs/runbooks/db-connectivity.md"
    assert "60 requests failed with database errors, 20 readiness probe failures" in db["evidence"]


def test_identical_errors_share_one_signature(db_outage_lines):
    report = analyze(parse_lines(db_outage_lines))
    top = report.signatures[0]
    assert top["message"] == "database_unavailable"
    assert top["count"] == 60
    assert top["first_seen"].startswith("2026-10-21T10:05")
    assert len(top["example_request_ids"]) == 5
    # Non-JSON lines are surfaced, not silently dropped
    assert any(s["key"] == "unparsed" and s["count"] == 1 for s in report.signatures)


def test_normalize_collapses_variable_parts():
    a = normalize("timeout to 10.10.8.4:5432 after 5003 ms (req 9c2318ffaa00bb11cc22dd33ee44ff55)")
    b = normalize("timeout to 10.10.8.9:5432 after 4999 ms (req 0123456789abcdef0123456789abcdef)")
    assert a == b == "timeout to <ip> after <n> ms (req <hex>)"


def test_route_latency_and_probe_exclusion():
    lines = [
        access(f"2026-10-21T10:00:{i:02d}.000+00:00", "/api/v1/aircraft", 200, ms=float(i))
        for i in range(1, 41)
    ]
    lines += [access("2026-10-21T10:00:59.000+00:00", "/readyz", 503)] * 50
    report = analyze(parse_lines(lines))
    assert report.totals["requests"] == 40  # probes excluded from SLO math
    route = report.routes[0]
    assert route["route"] == "/api/v1/aircraft"
    assert route["p50_ms"] == 20.5
    assert route["p95_ms"] == pytest.approx(38.05, abs=0.06)  # rounded to 0.1 ms


def test_slow_failures_do_not_raise_latency_findings():
    """Drill 001 regression: 2s DB-timeout 503s are an availability problem."""
    lines = [
        access(f"2026-10-21T10:00:{i:02d}.000+00:00", "/api/v1/sorties", 200, ms=10.0)
        for i in range(40)
    ]
    lines += [
        access(f"2026-10-21T10:01:{i:02d}.000+00:00", "/api/v1/sorties", 503, ms=2014.0)
        for i in range(10)
    ]
    report = analyze(parse_lines(lines))
    assert report.routes[0]["p95_ms"] == 10.0
    assert not any(f["title"].startswith("Slow route") for f in report.findings)


def test_gateway_5xx_without_upstream_means_no_ready_pods():
    lines = [
        gateway(f"2026-10-21T10:00:{i:02d}.000+00:00", "/api/v1/sorties", 503, upstream="-")
        for i in range(30)
    ]
    report = analyze(parse_lines(lines))
    assert any(
        f["title"] == "Gateway returned 5xx without reaching any pod" for f in report.findings
    )


def test_k8s_events_surface_oom_and_image_pull():
    events = [
        {
            "time": "t1",
            "reason": "Failed",
            "object": "Pod/a",
            "message": 'Failed to pull image "acr/sortie-tracker:nope": ErrImagePull',
            "count": 3,
        },
        {
            "time": "t2",
            "reason": "BackOff",
            "object": "Pod/b",
            "message": "Back-off restarting failed container api (last state: OOMKilled)",
            "count": 5,
        },
    ]
    report = analyze([], events)
    titles = {f["title"] for f in report.findings}
    assert {"New pods cannot pull their image", "Containers are being OOM-killed"} <= titles


def test_business_rule_spike_is_info_not_outage():
    lines = []
    for i in range(100):
        ts = f"2026-10-21T10:01:{i % 60:02d}.000+00:00"
        lines.append(
            app_line(
                ts, "business_rule_violation", level="WARNING", rule="aircraft_not_mission_capable"
            )
        )
        lines.append(access(ts, "/api/v1/sorties", 409))
    report = analyze(parse_lines(lines))
    assert report.findings[0]["severity"] == "info"
    assert report.findings[0]["title"] == "Spike in rejected requests: aircraft_not_mission_capable"
    assert report.totals["error_5xx"] == 0


def test_trace_follows_one_request_across_gateway_and_app(db_outage_lines):
    records = parse_lines(db_outage_lines)
    rid = "bad" + "0" * 29
    hops = trace(records, rid)
    assert [h["source"] for h in hops] == ["app", "app", "gateway"]


def test_kubectl_prefix_is_parsed():
    records = parse_lines(["[pod/sortie-tracker-abc/api] " + access("t", "/api/v1/aircraft", 200)])
    assert records[0].source == "app"
    assert records[0].data["origin"] == "pod/sortie-tracker-abc/api"


def test_text_render_smoke(db_outage_lines):
    text = render_text(analyze(parse_lines(db_outage_lines)))
    assert "FINDINGS" in text and "db-connectivity.md" in text


def test_stale_k8s_events_are_outside_the_window():
    """Drill 001 regression: hour-old events from a resolved incident misled triage."""
    from datetime import UTC, datetime

    from log_analyzer import events_since

    now = datetime(2026, 10, 21, 6, 0, tzinfo=UTC)
    events = [
        {"time": "2026-10-21T05:20:00Z", "reason": "Unhealthy", "message": "old"},
        {"time": "2026-10-21T05:59:30Z", "reason": "BackOff", "message": "fresh"},
        {"time": "", "reason": "Failed", "message": "undated"},
    ]
    kept = [e["message"] for e in events_since(events, "90s", now=now)]
    assert kept == ["fresh", "undated"]


def test_startup_probe_noise_is_not_a_pod_problem():
    events = [
        {
            "time": "t",
            "reason": "Unhealthy",
            "object": "Pod/a",
            "count": 1,
            "message": 'Startup probe failed: Get "http://10.0.0.1:8000/healthz": connection refused',
        },
    ]
    report = analyze([], events)
    assert report.findings[0]["title"] == "No anomalies detected"
