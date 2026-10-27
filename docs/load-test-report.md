# Load test results

**This file is empty on purpose.** It is filled by `scripts/load-test.sh` from
a real run against a real deployment, and nothing else should write to it.

The same rule as `image-size-report.md`: a placeholder metric is worse than no
metric. "Handles 500 rps" invented from nothing is a number that falls apart
the moment anyone asks how it was measured. Until there is a row in the table
below, the honest answer to "how does it perform under load" is **"I have not
measured it"**, and that is what the limitations table says.

## How to fill it

```bash
make load URL="$(terraform -chdir=terraform output -json service_urls | jq -r .finsight)"
```

Profiles:

| profile | duration | question it answers |
|---|---|---|
| `ramp` (default) | ~2 min | What does it do under a load it should handle? |
| `stress` | ~3 min | Where does it fall over? |
| `soak` | ~22 min | Does it degrade over time? This is the one that finds a connection-pool leak. |

```bash
./scripts/load-test.sh <url> stress
```

## What is being measured

One Fargate task — 512 CPU units, 1GB — running nginx and uvicorn in a single
task definition, behind one ALB, against a `db.t3.micro`. `desired_count = 1`,
no autoscaling.

These numbers describe **one task**. They say nothing about how the service
scales, because it does not: scaling is a `desired_count` change that doubles
the compute line, and web and api cannot scale independently because they share
a task (ADR 0002).

Thresholds in `load/smoke.js` are deliberately the same as the CloudWatch
alarms — p95 under 2s, error rate under 1% against the 99% availability SLO —
so a passing load test and a quiet alarm mean the same thing. A breach exits
non-zero. That is a result, not a broken script.

## Results

| date | profile | rps | error rate | p50 | p95 | p99 | notes |
|---|---|---|---|---|---|---|---|
