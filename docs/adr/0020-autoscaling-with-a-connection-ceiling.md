# 0020 — Autoscaling, bounded by the connection budget

- **Status:** Accepted
- **Date:** 2026-10-21
- **Source:** Read off peer repositories in this domain; see ADR 0018 for how they were chosen.

## Context

`desired_count = 1` was a listed weakness: a Spot reclaim is an outage and there is no headroom for a spike. Peers had CPU target-tracking autoscaling; this project had none.

The reason it was not simply added is that **scaling out multiplies database connections**, and the manifest's connection budget was computed against `desired_count`. Autoscaling without changing that check would let the service scale itself past `db.t3.micro`'s ~87 connection limit — and that failure appears as healthy tasks that cannot serve.

## Decision

Target-tracking on average CPU, **off by default**, with `min_capacity = desired_count` so enabling it changes nothing until load arrives. `scale_out_cooldown` 60s, `scale_in_cooldown` 300s — scale out fast, scale in slowly, because every scale-out pays a cold start.

`scripts/validate-manifest.sh` now takes `AUTOSCALING_MAX` and multiplies the peak by it. CI passes it the same value as `autoscaling_max_capacity`. The current manifest passes at 2 and **fails at 4**, which is the check working.

## Consequences

**Good.** The weakness is closed, and closed safely: the thing that would have made autoscaling dangerous is now a gate that fails the build.

**Bad.** The budget is checked against a value passed in by hand rather than read from Terraform. If `autoscaling_max_capacity` is raised and the CI environment variable is not, the check silently validates the wrong ceiling. Reading it from the tfvars would need the validator to parse HCL.

**Also.** Target tracking reacts to CPU, and this workload's bottleneck is more likely the database. A service can be at 40% CPU and completely blocked on connections, and CPU-based scaling will not notice.
