# 0015 — Build the expensive options, default them off

- **Status:** Accepted
- **Date:** 2026-09-20

## Context

`docs/cost-breakdown.md` carried a table titled "what is deliberately NOT here,
and what it would have cost": NAT gateway, VPC endpoints, EKS, multi-AZ RDS,
Container Insights, WAF, Performance Insights, ALB access logs, multi-region.

That table is good interview material and it has a weakness. Every row is an
assertion about work that does not exist. "I decided not to build a NAT
gateway" and "I did not know how to build a NAT gateway" produce an identical
repository, and a reader cannot tell them apart.

The obvious fixes are both bad. Building them on makes a portfolio project cost
$250/month. Leaving them out keeps the ambiguity.

## Decision

Build them. Default every one of them to **off**.

The default `terraform apply` is unchanged — same resources, same
~$0.033/hour. Each previously-absent capability is now one variable, and the
variable's description states what turning it on costs:

| Variable | Cost when on |
|---|---|
| `enable_private_subnets` | $0 alone, and non-functional alone |
| `enable_nat_gateway` | ~$32/month per gateway |
| `enable_vpc_endpoints` | ~$7.20/month per endpoint per AZ |
| `enable_waf` | ~$8/month all in |
| `enable_flow_logs` | ~$0.50/GB |
| `enable_alb_access_logs` | ~$0.50/month |
| `rds_multi_az` | ~2× the RDS line |
| `rds_performance_insights` | ~$2–5/month |
| `rds_enhanced_monitoring_interval` | ~$2–5/month |
| `enable_container_insights` | ~$3–8/month |

`scripts/cost-estimate.sh` (`make cost`) prices whatever combination a tfvars
file sets, and reports the multiple against the default.

Two stay documents rather than switches: **EKS** (`docs/eks-migration.md`) and
**multi-region**. Both are a second copy of the architecture rather than a
resource behind a flag — EKS would mean a parallel deployment path, a parallel
rollback mechanism and a parallel runbook, roughly doubling the repository to
demonstrate behaviour the ECS circuit breaker already demonstrates. Knowing
where that line falls is itself the decision.

## Consequences

**Good.** The cost table stops being a claim and becomes a configuration. The
interview answer moves from "I decided not to" to "it is one variable, here is
what it costs, here is why it is off" — and the second is checkable.

It also surfaced real work. Building the private path meant the ECS module
finally had to stop hardcoding `assign_public_ip = true`, the RDS endpoint had
to become conditional on topology, and the networking module grew a
`workload_subnet_ids` output so no other module has to know which topology is
in force. None of that existed while the option was a paragraph.

**Bad — and this is the real risk.** The blast radius of a one-character edit
went up sharply. `default = false` becoming `default = true` on
`enable_nat_gateway` is a $32/month change that looks like nothing in a diff.

That is mitigated, not eliminated, by two policy rules:

- every billable resource must be gated behind `count` or `for_each`, so
  nothing expensive can be created unconditionally, and
- every expensive switch must default to off **and name its price in its
  description**.

The second rule caught two descriptions that stated no price on its first run,
which is the argument for having written it.

**Also bad.** Nine of these paths are validated, policy-checked and never
applied. `terraform validate` proves the HCL is coherent; it does not prove a
NAT gateway in this configuration actually routes. The honest claim is "built
and unexercised", and it belongs in the limitations table alongside TLS — which
has exactly the same status and for exactly the same reason.
