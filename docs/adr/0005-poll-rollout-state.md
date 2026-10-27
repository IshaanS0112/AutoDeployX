# 0005 — Poll rolloutState, never 'aws ecs wait services-stable'

- **Status:** Accepted
- **Date:** 2026-08-24

## Context

After `aws ecs update-service`, the pipeline has to decide whether the
deploy worked. The obvious command is `aws ecs wait services-stable`.

It is wrong, for a specific and non-obvious reason: **a service that the
circuit breaker has just rolled back is perfectly stable.** `wait
services-stable` returns success for it.

## Decision

`scripts/deploy.sh` polls the PRIMARY deployment's `rolloutState`, which
distinguishes `IN_PROGRESS`, `COMPLETED`, `FAILED`,
`ROLLBACK_IN_PROGRESS` and `ROLLBACK_SUCCESSFUL`.

## Consequences

**Good.** A rolled-back deploy fails the pipeline instead of reporting green.
Without this, the exact failure the circuit breaker exists to catch is hidden
by the tool used to watch it.

**Bad.** More code than one `wait` call, including a poll loop and a timeout.
The loop also has to read `--output text` with `IFS=$'\t'`, because
`rolloutStateReason` is an English sentence and the default IFS splits it on
spaces — putting the reason's second word into the running-count variable.
