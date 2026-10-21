#!/usr/bin/env python3
"""Triage Sortie Tracker incidents from structured logs.

Collects JSON logs from the app pods and the Envoy gateway (kubectl), from
Azure Log Analytics (Container Insights), or from files, then produces:

  - traffic summary: requests, status mix, 5xx ratio vs the 99% SLO
  - per-route latency (p50/p95) and error rates, from the app's access logs
  - error signatures: identical errors grouped (numbers/IDs normalized),
    with counts, first/last seen and example request IDs
  - gateway vs app comparison (5xx the app never saw = pods unreachable)
  - Kubernetes warning events (OOMKilled, BackOff, failed probes)
  - findings: deterministic, rule-based conclusions linked to runbooks
  - request trace: every log line for one X-Request-ID across gateway + app

    log_analyzer.py --kubectl --since 30m
    log_analyzer.py --file incident.jsonl --json
    log_analyzer.py --log-analytics <workspace-guid> --since 1h
    log_analyzer.py --kubectl --trace 9c2318...      # follow one request
    log_analyzer.py --kubectl --ai                    # + Claude incident draft

Standard library only (the --ai option additionally needs `anthropic`).
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from statistics import quantiles

SLO_ERROR_BUDGET = 0.01  # 99% success
QUIET_ROUTES = {"/healthz", "/readyz", "/metrics"}
RUNBOOKS = "docs/runbooks"

KQL_APP_LOGS = """
ContainerLogV2
| where TimeGenerated > ago({since})
| where PodNamespace in ("sortie-tracker", "envoy-gateway-system")
| project TimeGenerated, PodName, ContainerName, LogMessage
| order by TimeGenerated asc
"""

_NORMALIZERS = [
    (
        re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b", re.I),
        "<uuid>",
    ),
    (re.compile(r"\b[0-9a-f]{16,}\b", re.I), "<hex>"),
    (re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b"), "<ip>"),
    (re.compile(r"\b\d+\b"), "<n>"),
]


def normalize(text: str) -> str:
    """Collapse variable parts so identical failures share one signature."""
    for pattern, replacement in _NORMALIZERS:
        text = pattern.sub(replacement, text)
    return text[:240]


# --------------------------------------------------------------------------- data


@dataclass
class Record:
    source: str  # app | gateway | unparsed
    timestamp: str
    data: dict

    @property
    def request_id(self) -> str | None:
        return self.data.get("request_id")


@dataclass
class Signature:
    key: str
    level: str
    logger: str
    message: str
    detail: str
    count: int = 0
    first_seen: str = ""
    last_seen: str = ""
    example_request_ids: list[str] = field(default_factory=list)


@dataclass
class Finding:
    severity: str  # critical | warning | info
    title: str
    evidence: str
    runbook: str | None = None


@dataclass
class Report:
    window: dict
    totals: dict
    routes: list[dict]
    signatures: list[dict]
    rule_violations: dict
    gateway: dict
    timeline: list[dict]
    k8s_events: list[dict]
    findings: list[dict]


# ------------------------------------------------------------------- collection


def parse_lines(lines, source_hint: str | None = None) -> list[Record]:
    records = []
    for raw in lines:
        line = raw.strip()
        if not line:
            continue
        # `kubectl logs --prefix` -> "[pod/name/container] {json}"
        prefix = ""
        if line.startswith("[") and "] " in line:
            prefix, line = line[1:].split("] ", 1)
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            records.append(Record("unparsed", "", {"line": line[:500], "origin": prefix}))
            continue
        if not isinstance(data, dict):
            continue
        if "logger" in data and "level" in data:
            source = "app"
            ts = data.get("timestamp", "")
        elif "upstream" in data or ("method" in data and "status" in data):
            source = "gateway"
            ts = data.get("start_time", "")
        else:
            source = source_hint or "unparsed"
            ts = data.get("timestamp", "")
        data.setdefault("origin", prefix)
        records.append(Record(source, ts, data))
    return records


def run(argv: list[str]) -> str:
    proc = subprocess.run(argv, capture_output=True, text=True, check=False)  # noqa: S603
    if proc.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(argv)}\n{proc.stderr.strip()}")
    return proc.stdout


def collect_kubectl(namespace: str, since: str) -> tuple[list[Record], list[dict]]:
    # --tail=-1 on both calls: with a label selector, kubectl defaults to the
    # last 10 lines per container, silently overriding --since.
    app = run(
        [
            "kubectl",
            "-n",
            namespace,
            "logs",
            "-l",
            "app.kubernetes.io/name=sortie-tracker",
            "--all-containers",
            "--prefix",
            f"--since={since}",
            "--tail=-1",
            "--max-log-requests=20",
            "--ignore-errors",
        ]
    )
    gateway = run(
        [
            "kubectl",
            "-n",
            "envoy-gateway-system",
            "logs",
            "-l",
            "gateway.envoyproxy.io/owning-gateway-name=hangar-gateway",
            "-c",
            "envoy",
            "--prefix",
            f"--since={since}",
            "--tail=-1",
            "--ignore-errors",
        ]
    )
    events = json.loads(run(["kubectl", "-n", namespace, "get", "events", "-o", "json"]))
    warnings = [
        {
            "time": e.get("lastTimestamp") or e.get("eventTime") or "",
            "reason": e.get("reason"),
            "object": f"{e['involvedObject'].get('kind')}/{e['involvedObject'].get('name')}",
            "message": e.get("message", "")[:300],
            "count": e.get("count", 1),
        }
        for e in events.get("items", [])
        if e.get("type") == "Warning"
    ]
    return parse_lines(app.splitlines()) + parse_lines(gateway.splitlines()), events_since(
        warnings, since
    )


def parse_duration(text: str) -> timedelta:
    match = re.fullmatch(r"(\d+)([smhd])", text)
    if not match:
        raise SystemExit(f"--since must look like 90s, 30m, 2h or 1d, got {text!r}")
    value, unit = int(match.group(1)), match.group(2)
    return timedelta(**{{"s": "seconds", "m": "minutes", "h": "hours", "d": "days"}[unit]: value})


def events_since(events: list[dict], since: str, now: datetime | None = None) -> list[dict]:
    """Kubernetes keeps events for an hour; drop those older than the window so
    an earlier, already-resolved problem cannot mislead this triage."""
    cutoff = (now or datetime.now(UTC)) - parse_duration(since)
    kept = []
    for e in events:
        try:
            when = datetime.fromisoformat(e["time"].replace("Z", "+00:00"))
        except (KeyError, ValueError):
            kept.append(e)  # undated: keep rather than hide
            continue
        if when >= cutoff:
            kept.append(e)
    return kept


def collect_log_analytics(workspace: str, since: str) -> list[Record]:
    if not re.fullmatch(r"\d+[mhd]", since):
        raise SystemExit(f"--since must look like 30m, 2h or 1d, got {since!r}")
    kql = KQL_APP_LOGS.format(since=since)  # KQL timespan literals use the same syntax
    rows = json.loads(
        run(
            [
                "az",
                "monitor",
                "log-analytics",
                "query",
                "--workspace",
                workspace,
                "--analytics-query",
                kql,
                "-o",
                "json",
            ]
        )
    )
    return parse_lines(
        f"[{r.get('PodName')}/{r.get('ContainerName')}] {r.get('LogMessage')}" for r in rows
    )


def collect_files(paths: list[str]) -> list[Record]:
    records = []
    for p in paths:
        if p == "-":
            records += parse_lines(sys.stdin)
            continue
        with Path(p).open(encoding="utf-8") as fh:
            records += parse_lines(fh)
    return records


# --------------------------------------------------------------------- analysis


def percentile(values: list[float], q: int) -> float | None:
    if not values:
        return None
    if len(values) == 1:
        return values[0]
    return quantiles(values, n=100, method="inclusive")[q - 1]


def analyze(records: list[Record], k8s_events: list[dict] | None = None) -> Report:
    k8s_events = k8s_events or []
    app = [r for r in records if r.source == "app"]
    gateway = [r for r in records if r.source == "gateway"]
    requests = [r.data for r in app if r.data.get("message") == "request"]
    api_requests = [r for r in requests if r.get("route") not in QUIET_ROUTES]

    status = Counter(str(r.get("status_code")) for r in api_requests)
    errors_5xx = sum(v for k, v in status.items() if k.startswith("5"))
    total = len(api_requests)

    # Per-route latency and errors
    by_route: dict[str, list[dict]] = defaultdict(list)
    for r in api_requests:
        by_route[r.get("route", "?")].append(r)
    routes = []
    for route, items in sorted(by_route.items(), key=lambda kv: -len(kv[1])):
        # Latency SLI over successful requests only: failures belong to the
        # availability SLI. (Drill 001: counting 2s DB-timeout 503s as "slow
        # routes" double-reported one outage and pointed at the wrong runbook.)
        durations = sorted(
            float(i.get("duration_ms", 0))
            for i in items
            if not str(i.get("status_code", "")).startswith("5")
        )
        route_5xx = sum(1 for i in items if str(i.get("status_code", "")).startswith("5"))
        route_4xx = sum(1 for i in items if str(i.get("status_code", "")).startswith("4"))
        routes.append(
            {
                "route": route,
                "requests": len(items),
                "error_5xx": route_5xx,
                "error_4xx": route_4xx,
                "p50_ms": round(percentile(durations, 50) or 0, 1),
                "p95_ms": round(percentile(durations, 95) or 0, 1),
            }
        )

    # Error signatures (WARNING and above, excluding access-log lines)
    sigs: dict[str, Signature] = {}
    for r in app:
        level = r.data.get("level", "")
        if level not in ("WARNING", "ERROR", "CRITICAL") or r.data.get("message") == "request":
            continue
        detail = r.data.get("rule") or r.data.get("error_type") or r.data.get("error") or ""
        key = normalize(f"{level}|{r.data.get('logger')}|{r.data.get('message')}|{detail}")
        sig = sigs.get(key) or Signature(
            key=key,
            level=level,
            logger=r.data.get("logger", ""),
            message=r.data.get("message", ""),
            detail=normalize(str(detail)),
        )
        sig.count += 1
        sig.first_seen = min(filter(None, [sig.first_seen, r.timestamp]), default="")
        sig.last_seen = max(sig.last_seen, r.timestamp)
        if r.request_id and len(sig.example_request_ids) < 5:
            sig.example_request_ids.append(r.request_id)
        sigs[key] = sig
    unparsed = [r for r in records if r.source == "unparsed"]
    if unparsed:
        sigs["unparsed"] = Signature(
            key="unparsed",
            level="UNPARSED",
            logger="-",
            message="non-JSON log lines",
            detail=normalize(unparsed[0].data.get("line", "")),
            count=len(unparsed),
        )
    signatures = sorted(sigs.values(), key=lambda s: -s.count)

    rule_violations = Counter(
        r.data.get("rule") for r in app if r.data.get("message") == "business_rule_violation"
    )

    # Gateway view: 5xx seen at the edge vs 5xx produced by the app
    gw_status = Counter(str(g.data.get("status")) for g in gateway)
    gw_5xx = sum(v for k, v in gw_status.items() if k.startswith("5"))
    gw_no_upstream = sum(
        1
        for g in gateway
        if str(g.data.get("status")).startswith("5") and g.data.get("upstream") in (None, "-", "")
    )

    # Per-minute timeline
    buckets: dict[str, Counter] = defaultdict(Counter)
    for r in api_requests:
        minute = str(r.get("timestamp", ""))[:16]
        buckets[minute]["requests"] += 1
        if str(r.get("status_code", "")).startswith("5"):
            buckets[minute]["5xx"] += 1
    for r in app:
        if r.data.get("level") in ("ERROR", "CRITICAL"):
            buckets[r.timestamp[:16]]["errors"] += 1
    timeline = [{"minute": m, **dict(c)} for m, c in sorted(buckets.items()) if m]

    timestamps = sorted(r.timestamp for r in records if r.timestamp)
    report = Report(
        window={
            "from": timestamps[0] if timestamps else None,
            "to": timestamps[-1] if timestamps else None,
            "app_lines": len(app),
            "gateway_lines": len(gateway),
            "unparsed_lines": len(unparsed),
        },
        totals={
            "requests": total,
            "status": dict(status),
            "error_5xx": errors_5xx,
            "error_ratio": round(errors_5xx / total, 4) if total else 0.0,
        },
        routes=routes,
        signatures=[asdict(s) for s in signatures],
        rule_violations=dict(rule_violations),
        gateway={
            "requests": len(gateway),
            "status": dict(gw_status),
            "error_5xx": gw_5xx,
            "no_upstream_5xx": gw_no_upstream,
        },
        timeline=timeline,
        k8s_events=k8s_events,
        findings=[],
    )
    report.findings = [asdict(f) for f in derive_findings(report)]
    return report


def derive_findings(report: Report) -> list[Finding]:
    """Rule-based conclusions an on-call engineer would draw first."""
    findings: list[Finding] = []
    t = report.totals
    sig_names = {s["message"]: s for s in report.signatures}

    if t["requests"] and t["error_ratio"] > SLO_ERROR_BUDGET:
        burn = t["error_ratio"] / SLO_ERROR_BUDGET
        findings.append(
            Finding(
                "critical" if burn >= 14.4 else "warning",
                f"5xx ratio {t['error_ratio']:.1%} exceeds the 1% SLO budget ({burn:.0f}x burn)",
                f"{t['error_5xx']} of {t['requests']} API requests failed",
                f"{RUNBOOKS}/high-error-rate.md",
            )
        )

    db = [
        s for s in report.signatures if s["message"] in ("database_unavailable", "database_error")
    ]
    ready = sig_names.get("readiness_check_failed")
    if db or ready:
        count = sum(s["count"] for s in db)
        span = (
            (db[0]["first_seen"], db[0]["last_seen"])
            if db
            else (ready["first_seen"], ready["last_seen"])
        )
        findings.append(
            Finding(
                "critical",
                "PostgreSQL unreachable from the API pods",
                f"{count} requests failed with database errors"
                + (f", {ready['count']} readiness probe failures" if ready else "")
                + f" between {span[0]} and {span[1]}",
                f"{RUNBOOKS}/db-connectivity.md",
            )
        )

    g = report.gateway
    if g["error_5xx"] > t["error_5xx"] and g["no_upstream_5xx"]:
        findings.append(
            Finding(
                "critical",
                "Gateway returned 5xx without reaching any pod",
                f"{g['no_upstream_5xx']} gateway 5xx had no upstream: "
                "no ready endpoints behind the Service",
                f"{RUNBOOKS}/pod-failures.md",
            )
        )

    # A startup probe failing while a new container boots is the probe doing its
    # job (every pod-kill/rollout produces one), not a pod problem.
    reasons = Counter(
        e["reason"]
        for e in report.k8s_events
        if not str(e.get("message", "")).startswith("Startup probe failed")
    )
    pod_problems = {
        r: n
        for r, n in reasons.items()
        if r in ("BackOff", "Failed", "FailedScheduling", "Unhealthy", "OOMKilling", "Killing")
    }
    oom = [
        e for e in report.k8s_events if "OOMKilled" in e["message"] or e["reason"] == "OOMKilling"
    ]
    pull = [
        e
        for e in report.k8s_events
        if "ImagePull" in e["message"] or "ErrImagePull" in e["message"]
    ]
    if pull:
        findings.append(
            Finding(
                "warning",
                "New pods cannot pull their image",
                f"{len(pull)} events, e.g. {pull[0]['message'][:160]}",
                f"{RUNBOOKS}/pod-failures.md",
            )
        )
    if oom:
        findings.append(
            Finding(
                "warning",
                "Containers are being OOM-killed",
                f"{len(oom)} events, e.g. {oom[0]['message'][:160]}",
                f"{RUNBOOKS}/pod-failures.md",
            )
        )
    if pod_problems and not (pull or oom):
        findings.append(
            Finding(
                "warning",
                "Kubernetes reports pod problems",
                ", ".join(f"{r}={n}" for r, n in pod_problems.items()),
                f"{RUNBOOKS}/pod-failures.md",
            )
        )

    for rule, n in report.rule_violations.items():
        if t["requests"] and n / t["requests"] > 0.2 and n >= 50:
            findings.append(
                Finding(
                    "info",
                    f"Spike in rejected requests: {rule}",
                    f"{n} rejections ({n / t['requests']:.0%} of traffic); "
                    "likely one misbehaving client",
                    f"{RUNBOOKS}/business-rule-spike.md",
                )
            )

    slow = [r for r in report.routes if r["p95_ms"] > 500 and r["requests"] >= 20]
    for r in slow:
        findings.append(
            Finding(
                "warning",
                f"Slow route {r['route']}",
                f"p95 {r['p95_ms']} ms over {r['requests']} requests",
                f"{RUNBOOKS}/high-latency.md",
            )
        )

    if not findings:
        findings.append(
            Finding(
                "info", "No anomalies detected", f"{t['requests']} requests, {t['error_5xx']} 5xx"
            )
        )
    order = {"critical": 0, "warning": 1, "info": 2}
    return sorted(findings, key=lambda f: order[f.severity])


def trace(records: list[Record], request_id: str) -> list[dict]:
    hits = [r for r in records if r.request_id == request_id]
    return [
        {"source": r.source, "timestamp": r.timestamp, **r.data}
        for r in sorted(hits, key=lambda r: r.timestamp)
    ]


# ------------------------------------------------------------------------ output


def render_text(report: Report) -> str:
    out = []
    w, t, g = report.window, report.totals, report.gateway
    out.append(
        f"Window: {w['from']} -> {w['to']}  (app {w['app_lines']} lines, "
        f"gateway {w['gateway_lines']}, unparsed {w['unparsed_lines']})"
    )
    out.append(
        f"API requests: {t['requests']}  status {t['status']}  5xx ratio {t['error_ratio']:.2%}"
    )
    out.append(
        f"Gateway: {g['requests']} requests, {g['error_5xx']} 5xx "
        f"({g['no_upstream_5xx']} with no upstream)"
    )
    out.append("")
    out.append("FINDINGS")
    for f in report.findings:
        out.append(f"  [{f['severity'].upper():8}] {f['title']}")
        out.append(f"             {f['evidence']}")
        if f["runbook"]:
            out.append(f"             runbook: {f['runbook']}")
    out.append("")
    out.append("TOP ERROR SIGNATURES")
    for s in report.signatures[:8]:
        out.append(f"  {s['count']:>6}x {s['level']:8} {s['message']}  {s['detail']}")
        out.append(
            f"          {s['first_seen']} .. {s['last_seen']}  "
            f"e.g. {', '.join(s['example_request_ids'][:2])}"
        )
    out.append("")
    out.append("ROUTES")
    out.append(f"  {'route':42} {'reqs':>6} {'5xx':>5} {'4xx':>5} {'p50ms':>7} {'p95ms':>7}")
    for r in report.routes[:10]:
        out.append(
            f"  {r['route']:42} {r['requests']:>6} {r['error_5xx']:>5} {r['error_4xx']:>5} "
            f"{r['p50_ms']:>7} {r['p95_ms']:>7}"
        )
    if report.k8s_events:
        out.append("")
        out.append("KUBERNETES WARNINGS")
        for e in report.k8s_events[-8:]:
            out.append(f"  {e['time']} {e['reason']:16} {e['object']}: {e['message'][:110]}")
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--kubectl", action="store_true", help="read app + gateway pods and events")
    src.add_argument("--log-analytics", metavar="WORKSPACE_ID", help="query Container Insights")
    src.add_argument("--file", nargs="+", metavar="PATH", help="JSON-lines files ('-' = stdin)")
    parser.add_argument("--namespace", default="sortie-tracker")
    parser.add_argument("--since", default="30m", help="lookback window, e.g. 15m, 2h")
    parser.add_argument("--trace", metavar="REQUEST_ID", help="print every line for one request")
    parser.add_argument("--json", action="store_true", help="machine-readable report")
    parser.add_argument("--save-logs", metavar="PATH", help="write collected raw records (JSONL)")
    parser.add_argument("--ai", action="store_true", help="draft an incident summary with Claude")
    args = parser.parse_args(argv)

    events: list[dict] = []
    if args.kubectl:
        records, events = collect_kubectl(args.namespace, args.since)
    elif args.log_analytics:
        records = collect_log_analytics(args.log_analytics, args.since)
    else:
        records = collect_files(args.file)

    if args.save_logs:
        with Path(args.save_logs).open("w", encoding="utf-8") as fh:
            for r in records:
                fh.write(json.dumps({"_source": r.source, **r.data}) + "\n")

    if args.trace:
        for line in trace(records, args.trace):
            print(json.dumps(line))
        return 0

    report = analyze(records, events)
    print(json.dumps(asdict(report), indent=2) if args.json else render_text(report))

    if args.ai:
        from ai_triage import triage

        draft = triage(report, records)
        print("\n" + draft.render_markdown())
    critical = any(f["severity"] == "critical" for f in report.findings)
    return 2 if critical else 0


if __name__ == "__main__":
    sys.exit(main())
