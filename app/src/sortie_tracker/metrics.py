"""Prometheus metrics: RED metrics for HTTP plus business signals.

Route labels use the matched route template (/api/v1/sorties/{sortie_id}),
never the raw path, so label cardinality stays bounded.
"""

from prometheus_client import Counter, Gauge, Histogram

HTTP_REQUESTS = Counter(
    "http_requests_total",
    "HTTP requests by method, route template and status code.",
    ["method", "route", "status"],
)

HTTP_LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency by method and route template.",
    ["method", "route"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)

HTTP_IN_PROGRESS = Gauge(
    "http_requests_in_progress",
    "HTTP requests currently being served.",
    ["method"],
)

SORTIES_CREATED = Counter(
    "sortie_tracker_sorties_created_total",
    "Sorties scheduled, by mission type.",
    ["mission_type"],
)

SORTIE_TRANSITIONS = Counter(
    "sortie_tracker_sortie_transitions_total",
    "Sortie status transitions.",
    ["from_status", "to_status"],
)

BUSINESS_RULE_VIOLATIONS = Counter(
    "sortie_tracker_business_rule_violations_total",
    "Requests rejected by a business rule, by rule name.",
    ["rule"],
)

DB_ERRORS = Counter(
    "sortie_tracker_db_errors_total",
    "Database errors surfaced to callers, by exception type.",
    ["error_type"],
)
