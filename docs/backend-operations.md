# Backend operations

The parts of this project that are about running a backend rather than about
shipping one. Everything here is a failure mode that a green deploy does not
catch.

---

## The connection budget

`db.t3.micro` allows roughly **87** connections. Every task holds up to
`pool_size + max_overflow`, and a rolling deploy runs at **200%** — old and new
task sets are both connected for the duration.

```
peak = Σ (pool_size + max_overflow) × desired_count × 2
     + one per service running a migration
```

Current: `(5 + 2) × 1 × 2 × 2 = 28`, plus 1 = **29 against 87**.

`make lint` fails if that exceeds `87 − 10` (ten reserved for superuser and
maintenance). The numbers live in the `db{}` block of
[`services/services.json`](../services/services.json).

**Why this is a gate and not a comment.** Exhausting the pool does not fail the
deploy. ECS reports `COMPLETED`, the health check passes — it uses one
connection — and then real traffic arrives and every request gets
`FATAL: remaining connection slots are reserved`. The deploy is green and the
service is down.

Raising `desired_count` is therefore never just a capacity decision. Two tasks
doubles the peak to 57; three exceeds the budget.

### The two pool settings people get wrong

**`pool_recycle` (1800s).** RDS closes idle connections. A pooled socket the
server has already dropped fails the **next** request to borrow it — not the
one that idled. Recycling below the server's idle timeout turns an
intermittent, unreproducible error into no error at all.

**`pool_timeout` (10s, not the default 30).** A request that has waited thirty
seconds for a connection has already failed from the user's point of view.
Holding it converts an error into a timeout and occupies a worker that could
be serving someone else.

Above this scale the answer is **RDS Proxy**, which multiplexes connections so
task count stops being bounded by the database. It is a documented next step,
not something this workload needs.

---

## Shutdown ordering

Four numbers that have to line up, in [ADR 0017](adr/0017-connection-budget-and-graceful-shutdown.md):

| Setting | Value |
|---|---|
| nginx `proxy_read_timeout` | 25s |
| `api` container `stopTimeout` | 30s |
| `web` container `stopTimeout` | 25s |
| ALB `deregistration_delay` | 30s |

Order: **ALB stops routing → in-flight requests drain → uvicorn exits → ECS
reaps.**

Set `stopTimeout` below the drain window and the container is `SIGKILL`ed while
the ALB is still draining into it. The client sees a connection reset on a
deploy that reported success — which is indistinguishable, from the outside,
from a flaky network.

---

## Migrations

Run as a **separate one-off ECS task, before the rollout** — not as a container
in the service task, and not at application startup. [ADR 0016](adr/0016-migrations-as-a-separate-pre-rollout-task.md)
has the reasoning; the short version is that a container in the service task
runs once per *task*, so two or three times concurrently during a 200% rolling
deploy.

```bash
SERVICE_KEY=strategysphere IMAGE_TAG=a3f9c21b \
  CLUSTER=autodeployx-production ./scripts/migrate.sh
```

If it fails, `deploy` never runs and the previous revision keeps serving. Old
code, old schema — still consistent.

### Expand, migrate, contract

**The pipeline makes one deploy easy. It does not make the other two
unnecessary.**

Migrations run *before* the new code, so the new schema is live against the
**old** code for the four to six minutes of the rollout. Additive changes are
fine. Destructive ones are not — drop a column the old code still `SELECT`s and
every request it serves in that window fails.

| Step | Change | Deploy |
|---|---|---|
| **Expand** | Add the new column, nullable. Old code ignores it. | 1 |
| **Migrate** | Backfill. Write to both old and new. | 2 |
| **Contract** | Once nothing reads the old column, drop it. | 3 |

Three deploys to change a column's shape. That is the price of zero downtime.

### Before a risky migration

```bash
./scripts/db-snapshot.sh create
```

Point-in-time recovery is on with a 1-day window and is the better tool for
"undo the last twenty minutes". A manual snapshot is for keeping an exact state
past the retention window.

**A backup nobody has restored is a hypothesis:**

```bash
./scripts/db-snapshot.sh restore-drill   # restores to a NEW instance
./scripts/db-snapshot.sh cleanup         # it bills by the hour
```

A restore that completes and contains an empty schema has told you nothing —
check the tables before trusting the drill.

### If a migration fails partway

The schema is now between revisions and the pipeline has stopped, correctly.

**Roll forward with a fix.** Do not wire Alembic `downgrade` into the pipeline:
an automatic downgrade on a failed migration is how a partial migration becomes
a corrupted one.

---

## Correlation IDs

nginx generates `$request_id` per request, or honours an inbound
`X-Request-ID`, and puts it in the JSON access log as `correlation_id`. It is
forwarded upstream and returned on the response.

This is the field that turns *"a request was slow"* into *"**this** request was
slow, here is its nginx line, its uvicorn line, and the query it ran"*. Without
it, correlating two log streams means matching on timestamp and hoping.

```bash
curl -si https://<url>/api/health | grep -i x-request-id
```

Then paste it into the saved query `04-trace-one-request`.

---

## Saved queries

Eight CloudWatch Logs Insights queries are defined in Terraform, so they exist
before the incident rather than being reconstructed during it:

| | |
|---|---|
| `01-slowest-requests` | The tail, with correlation ids |
| `02-latency-percentiles-by-path` | p50/p95/p99 **per path** — a service-wide p95 is one number, per-path tells you where to look |
| `03-errors-with-correlation-id` | Every 5xx, traceable |
| `04-trace-one-request` | Paste a correlation id, get every line both containers wrote |
| `05-availability-against-slo` | The same number the burn-rate alarms compute, derived independently from the access log |
| `06-database-connection-errors` | The pool-exhaustion failure above, specifically |
| `07-rate-limited-clients` | Who is being shed |
| `08-what-happened-during-the-deploy` | Errors binned by minute across a rollout window |

Query 05 disagreeing with the burn-rate alarm is informative, not a bug: the
difference is requests the ALB answered **without reaching a target**, which is
a different fault with a different fix.

---

## Load shedding

nginx rate-limits `/api/` at 20 r/s per IP, burst 40, `nodelay`, returning
**429**. Static assets are not limited — a legitimate page load fetches a dozen
files at once.

One task against one `db.t3.micro` has a hard ceiling and will meet it before
the ALB notices anything is wrong. Shedding in nginx costs nothing. The WAF
rate limit (`enable_waf`) does the same job earlier, at the edge, for ~$8/month.

---

## Database console

```bash
./scripts/db-console.sh finsight                      # shell in the api container
./scripts/db-console.sh finsight "select count(*) from companies"
```

Through a **running task via ECS Exec**, not a direct connection:

1. **It works regardless of topology.** With `enable_private_subnets` there is
   no route from a laptop at all, and this path keeps working without a bastion.
2. **It is audited.** ECS Exec goes through SSM, which logs the session against
   an IAM principal. A psql connection from a laptop logs nothing beyond a
   Postgres connection record.

The credential never reaches your shell — `DATABASE_URL` is already in the
container's environment, injected from Secrets Manager at task start.

`psql` is deliberately **not** in the runtime image: it would be a package and
a CVE surface for something used a handful of times a year. The console is
built from the `psycopg2` the application already ships.
