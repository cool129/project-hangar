# ADR 0005: GenAI-assisted incident triage as a bounded, read-only agent

- **Status:** Accepted
- **Date:** 2026-10-21

## Context

The first 15 to 20 minutes of an incident go into assembling a picture: what is failing,
since when, for whom, and what changed. That work is pattern-matching over logs and
events, which a language model does well. In a government program, however, the model
must not see secrets, must not act on production, and must not be trusted blindly.

## Decision

Two layers, in this order:

1. **Deterministic analysis first** (`scripts/log_analyzer.py`, stdlib only). It groups
   errors into signatures, computes SLO burn and per-route latency, compares the gateway
   with the app, reads Kubernetes events, and emits rule-based findings linked to runbooks.
   It works with no AI, no network and no credentials, and stays the source of truth.
2. **Optional AI draft** (`--ai`, `scripts/ai_triage.py`). Claude (`claude-opus-5-5`)
   turns the analysis into an incident draft: severity, impact, timeline, probable cause,
   evidence, actions, runbook and open questions.

Guardrails on the AI layer:

| Risk | Control |
|------|---------|
| Leaking secrets / PII | The model gets **aggregates**, not raw logs; every string is **redacted** (credentials in URLs, bearer/JWT tokens, `password=`, emails, IPs) before it leaves the machine |
| Agent takes harmful action | Tools are **read-only views over data already collected** (signature samples, request trace, search). No cluster, cloud or network access |
| Runaway cost / loops | At most **6 tool rounds**; the final round forces an answer (`tool_choice: none`); token usage and estimated cost are printed |
| Prompt injection via log content | Log data is wrapped in `<logs>` and the system prompt declares it untrusted; instructions found in logs are never followed |
| Hallucination | The system prompt requires cited evidence (signatures, counts, request IDs) and `confidence: low` plus open questions when evidence is thin; output is **schema-constrained JSON** |
| Over-trust | Output is labelled *AI-generated draft, verify before sharing*; it never pages, posts or remediates |
| Safety-classifier false positives on security-flavoured logs | Server-side **refusal fallback** (`fallbacks: "default"`); a remaining refusal is reported, never parsed |

## Consequences

- Triage still works when the AI is unavailable or not approved for the environment.
  `--ai` is opt-in per run.
- For classified or IL5+ environments, the same code can target a provider deployment
  accredited for that level (e.g. Claude through a government cloud region). The
  redaction and aggregation layer stays mandatory either way.
- The agent loop is unit-tested with a scripted fake client: tool dispatch, redaction of
  tool results, error results for bad tool input, the round budget, and refusal handling.
  No API spend in CI.
