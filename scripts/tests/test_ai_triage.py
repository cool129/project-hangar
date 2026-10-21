"""The triage agent is tested against a scripted fake client: no API calls, no cost."""

import json
from types import SimpleNamespace

import pytest

import ai_triage
from ai_triage import MAX_TOOL_ROUNDS, TriageError, redact, triage
from log_analyzer import analyze, parse_lines

DRAFT = {
    "title": "API returning 503: PostgreSQL unreachable",
    "severity": "SEV1",
    "status": "ongoing",
    "customer_impact": "60% of sortie API calls failing since 10:05 UTC.",
    "timeline": [{"time": "10:05", "event": "First database_unavailable error"}],
    "probable_cause": "Pods cannot reach PostgreSQL (connection timeouts to the db subnet).",
    "confidence": "medium",
    "evidence": ["database_unavailable x60", "readiness_check_failed x20"],
    "recommended_actions": ["Check NetworkPolicy egress to 5432", "Check Flexible Server health"],
    "runbook": "db-connectivity.md",
    "open_questions": ["Did a NetworkPolicy change ship at 10:04?"],
}


def usage(i=1000, o=200):
    return SimpleNamespace(input_tokens=i, output_tokens=o, cache_read_input_tokens=0)


def tool_use(name, tool_input, tid="tu_1"):
    return SimpleNamespace(type="tool_use", id=tid, name=name, input=tool_input)


def text(payload):
    return SimpleNamespace(type="text", text=json.dumps(payload))


class FakeClient:
    """Mimics client.beta.messages.create and records every request."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self._create))

    def _create(self, **kwargs):
        self.requests.append(json.loads(json.dumps(kwargs, default=lambda o: o.__dict__)))
        return self.responses.pop(0)


@pytest.fixture
def incident(db_outage_lines):
    records = parse_lines(db_outage_lines)
    return analyze(records), records


def test_agent_investigates_then_returns_structured_draft(incident):
    report, records = incident
    rid = report.signatures[0]["example_request_ids"][0]
    client = FakeClient(
        [
            SimpleNamespace(
                stop_reason="tool_use",
                usage=usage(),
                content=[tool_use("trace_request", {"request_id": rid})],
            ),
            SimpleNamespace(stop_reason="end_turn", usage=usage(1200, 400), content=[text(DRAFT)]),
        ]
    )

    draft = triage(report, records, client=client)

    assert draft.severity == "SEV1"
    assert draft.tool_calls == ["trace_request"]
    assert (draft.input_tokens, draft.output_tokens) == (2200, 600)
    md = draft.render_markdown()
    assert "AI-generated draft" in md and "db-connectivity.md" in md

    first, second = client.requests
    assert first["model"] == "claude-opus-5-5"
    assert first["thinking"] == {"type": "adaptive"}
    assert first["fallbacks"] == "default"
    assert first["output_config"]["format"]["schema"] == ai_triage.INCIDENT_SCHEMA
    assert all(t["strict"] for t in first["tools"])
    # The tool result went back in one user message, matched to the tool_use id
    result = second["messages"][-1]["content"][0]
    assert result["tool_use_id"] == "tu_1" and result["is_error"] is False
    assert rid in result["content"]


def test_prompt_is_redacted_and_logs_are_marked_untrusted(incident):
    report, records = incident
    client = FakeClient(
        [SimpleNamespace(stop_reason="end_turn", usage=usage(), content=[text(DRAFT)])]
    )
    triage(report, records, client=client)

    prompt = client.requests[0]["messages"][0]["content"]
    assert "<logs>" in prompt and "</logs>" in prompt
    # The analyzer forwards normalized aggregates only, so raw IPs never reach the model.
    assert "10.10.8.4" not in prompt
    assert "untrusted data" in client.requests[0]["system"][0]["text"]


def test_tool_results_are_redacted(incident):
    report, records = incident
    client = FakeClient(
        [
            SimpleNamespace(
                stop_reason="tool_use",
                usage=usage(),
                content=[tool_use("search_logs", {"text": "timed out", "limit": 3})],
            ),
            SimpleNamespace(stop_reason="end_turn", usage=usage(), content=[text(DRAFT)]),
        ]
    )
    triage(report, records, client=client)
    result = client.requests[1]["messages"][-1]["content"][0]["content"]
    assert "timed out" in result
    assert "10.10.8.4" not in result
    assert "client_ip" not in result or "<redacted>" in result


def test_bad_tool_input_returns_error_result_instead_of_crashing(incident):
    report, records = incident
    client = FakeClient(
        [
            SimpleNamespace(
                stop_reason="tool_use",
                usage=usage(),
                content=[tool_use("get_signature_samples", {"signature_index": 999, "limit": 2})],
            ),
            SimpleNamespace(stop_reason="end_turn", usage=usage(), content=[text(DRAFT)]),
        ]
    )
    triage(report, records, client=client)
    result = client.requests[1]["messages"][-1]["content"][0]
    assert result["is_error"] is True and "signature_index" in result["content"]


def test_tool_budget_forces_an_answer(incident):
    report, records = incident
    looping = [
        SimpleNamespace(
            stop_reason="tool_use",
            usage=usage(),
            content=[tool_use("search_logs", {"text": "x", "limit": 1}, tid=f"t{i}")],
        )
        for i in range(MAX_TOOL_ROUNDS)
    ]
    client = FakeClient(
        [*looping, SimpleNamespace(stop_reason="end_turn", usage=usage(), content=[text(DRAFT)])]
    )
    draft = triage(report, records, client=client)

    assert len(client.requests) == MAX_TOOL_ROUNDS + 1
    assert client.requests[-1]["tool_choice"] == {"type": "none"}
    assert all(r["tool_choice"] == {"type": "auto"} for r in client.requests[:-1])
    assert len(draft.tool_calls) == MAX_TOOL_ROUNDS


def test_refusal_is_reported_not_parsed(incident):
    report, records = incident
    client = FakeClient(
        [
            SimpleNamespace(
                stop_reason="refusal",
                usage=usage(),
                content=[],
                stop_details=SimpleNamespace(category="cyber"),
            )
        ]
    )
    with pytest.raises(TriageError, match=r"declined.*cyber"):
        triage(report, records, client=client)


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        (
            "postgresql+psycopg://hangaradmin:S3cr3t!@psql.example:5432/db",
            "postgresql+psycopg://<redacted>@psql.example:5432/db",
        ),
        ("Authorization: Bearer abc.def-ghi", "Authorization: Bearer <token>"),
        ("password=hunter2 next", "password=<redacted> next"),
        ("contact ops@example.mil now", "contact <email> now"),
        ("from 203.0.113.9", "from <ip>"),
        ("eyJhbGciOiJ.eyJzdWIiOiIx.c2lnbmF0dXJl", "<jwt>"),
    ],
)
def test_redaction_patterns(raw, expected):
    assert redact(raw) == expected


def test_redaction_recurses_and_drops_sensitive_keys():
    out = redact({"client_ip": "1.2.3.4", "nested": [{"db_password": "x", "msg": "to 10.0.0.1"}]})
    assert out == {
        "client_ip": "<redacted>",
        "nested": [{"db_password": "<redacted>", "msg": "to <ip>"}],
    }
