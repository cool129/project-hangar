# Postmortem: <title>

> Blameless: describe systems and decisions, not individuals. Written within 5 business days.

| | |
|---|---|
| **Incident** | INC-<id> |
| **Severity** | SEV<n> |
| **Duration** | <start> to <end> UTC (<minutes> min) |
| **Detection** | <alert / user report>, <minutes> after onset |
| **Authors** | |

## Summary
Two or three sentences: what broke, who was affected, how it was fixed.

## Impact
Requests failed (count and %), error budget consumed, affected users or mission teams.

## Timeline (UTC)
| Time | Event |
|------|-------|

## Root cause
The underlying cause, and the trigger that exposed it.

## What went well / what didn't

## Action items
| Action | Type (prevent / detect / mitigate) | Owner | Due |
|--------|------------------------------------|-------|-----|

## Evidence
`log_analyzer.py` report, dashboards, migration/deploy IDs. If an AI draft was used, link it
and note which parts were confirmed or corrected.
