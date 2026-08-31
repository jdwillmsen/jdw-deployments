# YYYY-MM-DD — <short title>

| | |
|---|---|
| **Workload** | |
| **Detected** | |
| **Resolved** | |
| **Data loss** | |
| **User impact** | |

## Summary

Two or three sentences. What broke, what it cost, what caused it.

## Impact

What was actually lost or unavailable, and for whom. Quantify it.

## Timeline

All times UTC. Quote evidence verbatim; mark anything inferred as inferred.

```
HH:MM:SS  <log line or event>
```

## Root cause

The mechanism, stated so someone who was not there can follow it end to end.

## Contributing factors

Things that were not the cause but made it possible, worse, or slower to find.

## Hypotheses considered and rejected

Record the wrong turns and what disproved each one. This is the part that stops
the next investigation repeating them.

| Hypothesis | Why it looked right | What disproved it |
|---|---|---|
| | | |

## Detection

How it was noticed, and how long it ran unnoticed. What should have caught it.

## Resolution

What was actually done to restore service, step by step.

## Action items

| # | Action | Type | Status |
|---|--------|------|--------|
| 1 | | prevent / detect / mitigate | |

## Assumptions invalidated

Anything the codebase asserted as safe that this incident disproved. Add these
to the register in [README.md](README.md).
