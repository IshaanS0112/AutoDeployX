# 0012 — Error-budget burn rate alongside fixed thresholds

- **Status:** Accepted
- **Date:** 2026-09-20

## Context

The alarms this project shipped with are fixed thresholds: 'more than 5 errors
in a minute'. That is the right shape for a symptom you can name in advance and
the wrong shape for a commitment. Five errors a minute is catastrophic on a
service doing ten requests a minute and invisible on one doing ten thousand.

Anything that publishes a custom metric is out: custom metrics are not
free-tier eligible, and the project's stated constraint is that observability
costs nothing.

## Decision

Two burn-rate alarms per service, computed with CloudWatch **metric math**
over `RequestCount` and `HTTPCode_Target_5XX_Count` — both already
published by the ALB at no charge. Fast burn is 14.4x over one hour, slow burn
is 6x over six hours, against a 99% availability SLO.

99%, not 99.9%. This is one task on Fargate Spot behind one ALB with a
single-AZ database; 99.9% is 43 minutes a month and a single Spot reclaim can
spend a chunk of that.

## Consequences

**Good.** The alarm now asks 'at this rate, how fast is the month's error
budget being consumed', which is scale-independent. Two windows catch two
different failures: an outage in progress, and a slow bleed that never trips a
one-minute threshold but still exhausts the budget. Cost is zero.

**Bad.** A burn rate over a service with almost no traffic is noisy in the
other direction — a handful of errors against a handful of requests is a
enormous ratio. `treat_missing_data = "notBreaching"` handles the idle
case, but the low-traffic case is a real limitation of an SLO on a demo stack,
and `enable_slo_alarms = false` in the dev environment for exactly that
reason.

The fixed-threshold alarms stay. They answer 'is something broken right now',
which is a different question from 'are we going to miss the commitment'.
