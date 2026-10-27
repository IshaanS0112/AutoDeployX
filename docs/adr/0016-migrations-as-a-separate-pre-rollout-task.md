# 0016 — Schema migrations as a separate task, before the rollout

- **Status:** Accepted
- **Date:** 2026-09-28

## Context

Both deployed services created their schema with
`Base.metadata.create_all()` at application startup. That works exactly once.

`create_all` only ever **adds** tables. It will not alter a column, will not
add an index, will not rename anything and will not drop anything. So the
first schema change that is not a brand-new table deploys **silently** — no
error at boot, health check green, circuit breaker satisfied — and then fails
at runtime on the first query that touches the changed column.

The project needed a migration stage. Where to put it is the whole decision,
and the two obvious answers are both wrong.

**As a container in the service task.** A migration must run exactly once per
deploy. A container in the service task runs once per *task* — so at
`desired_count = 2`, or during a rolling deploy where old and new overlap, it
runs two or three times concurrently against one database. Alembic takes a
lock; the losers fail; a healthy deploy goes red for a reason unrelated to the
change being shipped.

**As an init container / at application startup.** Runs *after* the rollout has
begun, so the first new task is live against an unmigrated schema for as long
as the migration takes. It also reintroduces the concurrency problem.

## Decision

A **separate one-off ECS task definition** per service
(`terraform/modules/migrations/`), invoked by `scripts/migrate.sh` as a
dedicated pipeline job **between `build` and `deploy`**.

- It runs from the **same image** the deploy is about to ship. Running
  migrations from a different build applies a migration the deployed code does
  not expect.
- It runs with `DB_POOL_SIZE=1` and no overflow. A pool here would reserve
  connections the running service needs, during the rollout window when they
  are scarcest.
- `ecs:RunTask` is scoped in IAM to these task-definition families, with an
  `ecs:cluster` condition. Unlike `RegisterTaskDefinition`, `RunTask` *does*
  support resource-level permissions, so this one is genuinely contained.
- On failure the `deploy` job never runs. The previous revision keeps serving,
  and the schema it expects is still in place.
- `migrations.enabled` in `services/services.json` records which repos have
  adopted it — the same pattern as `checks.lint`, recording what is **true**
  today rather than what is intended.

## Consequences

**Good.** The migration either succeeds before any new code is live, or the
deploy does not happen. There is no window where new code meets an old schema.
The concurrency problem is gone by construction: one task, one run.

The IAM story is genuinely better than the task-definition one. `RunTask`
scoped to two families with a cluster condition is a real boundary, and it is
a useful contrast to draw against `RegisterTaskDefinition`, which cannot be
scoped at all.

**Bad — and this is the part that matters.** *Migrate-then-deploy* means the
new schema is live against the **old code** for the duration of the rollout,
which is four to six minutes. That is fine for an additive migration and
catastrophic for a destructive one: drop a column the old code still SELECTs
and every request it serves for those minutes fails.

The mitigation is not technical, it is procedural — **expand, migrate,
contract**:

1. **Expand.** Add the new column, nullable. Deploy. Old code ignores it.
2. **Migrate.** Backfill, and write to both old and new. Deploy.
3. **Contract.** Only once no running code reads the old column, drop it.
   Deploy.

Three deploys to change a column's shape. That is the cost of zero downtime,
and a pipeline that makes one deploy easy does not make the other two
unnecessary.

**Also bad.** A migration that fails *partway* leaves the schema between
revisions, and this pipeline cannot undo that — it stops, and correctly so.
Rolling **forward** with a fix is the answer; `scripts/db-snapshot.sh create`
before a risky migration is the seatbelt. Alembic `downgrade` is not wired into
the pipeline on purpose: an automatic downgrade on failure is how a partial
migration becomes a corrupted one.

**Still outstanding.** FinSight 360 has `migrations.enabled = false`, because
it still calls `create_all()`. The pipeline prints a warning saying exactly
that on every deploy rather than pretending the stage ran. StrategySphere AI
ships Alembic and already runs an upgrade/downgrade/upgrade round-trip in its
own CI, so its migrations are known reversible before this pipeline runs one.
