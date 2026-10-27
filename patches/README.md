# Patches for the deployed services

AutoDeployX deploys two repositories it does not own. Three changes are needed
in those repos; they live here as patches rather than as forks, so the service
repos stay the source of truth for their own code and you can read exactly what
is being changed before applying it.

## Apply order matters

For StrategySphere the two patches are **sequential**, not independent:

```
1. strategysphere-lint-parity.patch     establishes the standard
2. strategysphere-health-endpoint.patch a change that conforms to it
```

Both touch `backend/app/main.py` and `backend/tests/test_api.py`. The
lint-parity patch reformats most of the tree, so the health patch is generated
against the already-formatted file. Applying them the other way round fails on
context.

FinSight has one patch and no ordering question — it already ships a
`ruff.toml` and its CI already runs it.

```bash
cd ../FinSight-360
git apply --check ../AutoDeployX/patches/finsight-health-endpoint.patch   # dry run
git apply         ../AutoDeployX/patches/finsight-health-endpoint.patch
git commit -am "health: check the database and report the deployed commit"
```

```bash
cd ../StrategySphere-AI
git apply --check ../AutoDeployX/patches/strategysphere-lint-parity.patch
git apply         ../AutoDeployX/patches/strategysphere-lint-parity.patch
git commit -am "lint: adopt ruff, matching FinSight-360"

git apply --check ../AutoDeployX/patches/strategysphere-health-endpoint.patch
git apply         ../AutoDeployX/patches/strategysphere-health-endpoint.patch
git commit -am "health: check the database and report the deployed commit"
```

## Verification

Regenerated and re-verified on **20 September 2026** against each repo's
current `main`, because both had moved on since the patches were first written
and two of the three no longer applied. Verified means: applied to a fresh
checkout of the remote HEAD, then the repo's own suite and linter run.

| patch | applies to | after applying |
|---|---|---|
| `finsight-health-endpoint` | `FinSight-360@5972b98` | **245 passed**, ruff clean |
| `strategysphere-lint-parity` | `StrategySphere-AI@19bc632` | **226 passed**, ruff clean |
| `strategysphere-health-endpoint` | the above, patched | **226 passed**, ruff clean |

A patch set that is not re-verified against the current HEAD is a patch set
that has quietly stopped working. This is gate G5 in `docs/architecture.md`,
and it is the gate most likely to rot without anyone noticing, because nothing
in CI applies these.

---

## 1. `finsight-health-endpoint.patch` / `strategysphere-health-endpoint.patch`

**What was wrong.** Both services had:

```python
@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}
```

That endpoint returns 200 as long as the Python process is running. It returns
200 when the database is unreachable and every real request is 500ing. Put it
behind a load balancer and the load balancer will keep routing traffic to a
broken instance; put it in front of a deployment gate and a deploy that broke
the connection string passes its health check and goes to production green.

**What the patch does.** Splits it into two probes, because they answer two
different questions:

| endpoint | depth | used by | question it answers |
|---|---|---|---|
| `/health/live` | process only | container `HEALTHCHECK` | should this container be *restarted*? |
| `/health` | opens a DB connection, `SELECT 1` | ALB target group | should this instance get *traffic*? |

Restarting a container does not fix a database that is down, so the restart
probe must not depend on the database — otherwise a 30-second RDS blip becomes
a container restart storm on top of an outage. Conversely, an instance that
cannot reach its database should receive no traffic, so the ALB's probe must
check it.

`/health` returns **503** when unhealthy. That is what makes the ECS deployment
circuit breaker able to see a bad rollout and roll back.

It also returns the deployed commit:

```json
{
  "status": "healthy",
  "checks": { "database": "ok" },
  "commit": "a3f9c21b",
  "service": "finsight"
}
```

`commit` comes from `GIT_SHA`, injected at image build time. It is the field
that lets you read off a live URL exactly which commit is serving traffic, and
it is what `scripts/smoke-test.sh` asserts against after every deploy — so a
rollout that silently left the old revision in place fails the pipeline instead
of passing it.

**The tradeoff, stated rather than hidden.** With `desired_count = 1`, a
database outage longer than the unhealthy threshold (3 × 15s) takes the service
out of the load balancer entirely, where the old shallow check would at least
have kept serving the frontend. That is correct for a deployment gate and wrong
for availability. The fix is more than one task, not a shallower check.

**Also updated:** the existing test in each repo that asserted
`{"status": "ok"}`. Without that, the patch turns both repos' CI red — which is
how this was caught.

---

## 2. `strategysphere-lint-parity.patch`

Found while wiring StrategySphere into the pipeline, not by looking for it: the
pipeline's lint stage failed on a repo that had never been linted.

**What was wrong**, relative to its sibling FinSight-360, measured on
20 September 2026:

- No `backend/ruff.toml`, so no agreed line length or rule set
- `.github/workflows/ci.yml` ran tests and a migration round-trip, but never a
  linter
- **26 violations** against FinSight's rule set:

  | rule | count | what it is |
  |---|---|---|
  | `UP038` | 13 | `isinstance(x, (int, float))` instead of `int \| float` |
  | `B905` | 4 | `zip()` without an explicit `strict=` |
  | `SIM300` | 3 | Yoda conditions in assertions |
  | `SIM102` | 2 | collapsible nested `if` |
  | `I001` | 2 | unsorted imports |
  | `C408` | 1 | `dict()` where a literal would do |
  | `UP037` | 1 | quoted annotation that no longer needs quoting |

- 25 files unformatted

Two sibling repos in the same portfolio, written in the same sprint, with
different quality gates is the kind of inconsistency a reviewer notices.

**What the patch does.** Copies FinSight's `ruff.toml` verbatim, applies every
fix, and adds a pinned `ruff` step to the CI workflow. Ten violations were
auto-fixable, fourteen needed `--unsafe-fixes`, and the two `SIM102` collapses
were done by hand because ruff will not rewrite a nested `if` on its own.

Afterwards `ruff check` and `ruff format --check` are clean and all **226**
tests still pass — verified, not assumed.

The dead `SwotCategory` import the earlier version of this patch removed is
gone from upstream already; that part of the patch is no longer needed.

**After applying it,** set `checks.lint` to `true` for `strategysphere` in
`services/services.json`. Until then the pipeline skips that gate and prints a
warning saying why, rather than failing on a standard the repo never adopted.
