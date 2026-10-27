# 0017 — Size the connection pool against the instance, and drain in order

- **Status:** Accepted
- **Date:** 2026-09-28

## Context

Two failure modes that share a property: **the deploy succeeds, and the
service breaks afterwards.** Neither is caught by a health check, because a
health check is one request on one connection.

### Connection exhaustion

`db.t3.micro` allows roughly **87** connections. Each task holds up to
`pool_size + max_overflow`. A rolling deploy runs at `deployment_maximum_percent
= 200`, so during the rollout **both** the old and new task sets are connected
— the peak is double the steady-state count, plus one for the migration task.

With a default SQLAlchemy pool (5 + 10) and two services at `desired_count = 2`,
the peak is `15 × 2 × 2 × 2 = 120`. Over the limit, during the rollout, on a
deploy that ECS reports as `COMPLETED`. The first user request after that gets
`FATAL: remaining connection slots are reserved`.

### Ungraceful shutdown

ECS sends `SIGTERM`, waits `stopTimeout`, then `SIGKILL`. Independently, the
ALB stops routing to the target and waits `deregistration_delay` for in-flight
requests. If `stopTimeout` is shorter than the drain window, the container is
killed **while the ALB is still draining into it** — and a client sees a
connection reset on a deploy that reported success.

## Decision

**A connection budget, enforced in the manifest validator.**

`services/services.json` carries a `db{}` block per service, and
`scripts/validate-manifest.sh` computes:

```
peak = Σ (pool_size + max_overflow) × desired_count × 2
     + one per service with migrations enabled
```

and fails if it exceeds `87 − 10` (ten reserved for superuser and
maintenance). Current values are `5 + 2` per service, peak 28.

`pool_recycle` is set to 1800s and matters as much as the size: RDS closes
idle connections, and a pooled socket the server has already dropped fails the
**next** request to borrow it, not the one that idled. Recycling below that
window turns an intermittent error into no error.

`pool_timeout` is 10s, not the default 30. A request that has queued thirty
seconds for a connection has already failed from the user's point of view;
holding it just converts an error into a timeout.

**Shutdown ordering, with the numbers made to line up.**

| Setting | Value | Why |
|---|---|---|
| nginx `proxy_read_timeout` | 25s | Nothing upstream can legitimately run longer |
| `api` `stopTimeout` | 30s | Exceeds the longest in-flight request, with margin |
| `web` `stopTimeout` | 25s | nginx drains after the API; it has nothing of its own to finish |
| ALB `deregistration_delay` | 30s | The drain window `stopTimeout` must fit inside |

Order: ALB stops routing → in-flight requests drain → uvicorn exits → ECS
reaps.

## Consequences

**Good.** Both failures are now arithmetic rather than folklore, and the
arithmetic is a gate — `make lint` fails on a manifest whose pool maths does
not fit the instance. The numbers are in one place with the reasoning attached,
so raising `desired_count` surfaces the connection consequence immediately
instead of two deploys later.

**Bad.** The budget hardcodes 87 for `db.t3.micro`. Change the instance class
and the constant is wrong — it is overridable with `DB_MAX_CONNECTIONS`, which
is a workaround, not a fix. Reading `max_connections` from the live instance
would be correct and would mean the validator needs AWS credentials, which
would stop it running on a fork pull request. The constant was the trade.

**Also bad.** `pool_size = 5` is conservative enough to be a ceiling of its
own. Two tasks × 5 persistent connections is ten concurrent queries before
anything overflows; a genuinely busy service would want RDS Proxy, which
multiplexes and is the real answer above this scale. That is a documented next
step, not something this stack needs.

**Untested under load.** These numbers are derived, not observed. `load/smoke.js`
has a `soak` profile specifically because a connection-pool leak is invisible
in a two-minute ramp and obvious in a twenty-minute one — but it has not been
run against a live deployment, so the honest claim is "correctly sized on
paper".
