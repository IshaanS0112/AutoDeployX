# 0004 — Two health probes, shallow and deep

- **Status:** Accepted
- **Date:** 2026-08-23

## Context

Two different consumers ask health questions about a running task, and they
are asking different things.

The container health check decides whether ECS should **restart** the
container. The ALB target group health check decides whether this instance
should receive **traffic**.

## Decision

`/health/live` touches nothing external and is used by the container
`HEALTHCHECK`. `/health` opens a database connection, runs `SELECT 1`,
returns **503** when that fails, and is used by the ALB target group. It also
reports the deployed commit SHA from `GIT_SHA`.

## Consequences

**Good.** A 30-second RDS blip no longer becomes a container restart storm on
top of an outage, because the restart probe does not depend on the database.
An instance that cannot reach its database receives no traffic, because the
ALB probe does.

The 503 is load-bearing. It is what the ALB sees, what marks the target
unhealthy, and therefore **what the ECS circuit breaker reacts to**. A
`/health` that always returns 200 makes the entire rollback mechanism inert.

The commit field is what `scripts/smoke-test.sh` asserts against, so a
rollout that silently left the old revision serving traffic fails the pipeline
instead of passing it.

**Bad.** With one running task, a database outage longer than the unhealthy
threshold takes the whole service out of the load balancer rather than serving
the frontend with a broken API. That is correct for a deployment gate and
wrong for availability, and the fix is more than one task — not a shallower
check.

**Also.** Changing `/health` broke the existing test in both deployed
repositories, which asserted `== {"status": "ok"}` exactly. The patches
update the assertion in the same commit.
