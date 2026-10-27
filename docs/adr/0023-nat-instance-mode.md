# 0023 — A NAT instance mode at a tenth the cost

- **Status:** Accepted
- **Date:** 2026-10-21
- **Source:** Read off peer repositories in this domain; see ADR 0018 for how they were chosen.

## Context

`enable_nat_gateway` created managed NAT gateways at ~$32/month each. That is the production-correct answer and it is also more than the entire rest of this stack, which is why the private-subnet path stayed off by default and therefore unexercised.

A peer repository ran a `t4g.nano` as a NAT instance for about $3/month.

## Decision

`nat_mode`, defaulting to `"gateway"`. Setting it to `"instance"` runs one `t4g.nano` with `source_dest_check = false`, IMDSv2 required, an encrypted root volume, and a security group that accepts traffic only from inside the VPC.

The route table picks whichever exists. The cost estimator prices both.

## Consequences

**Good.** The private-subnet topology becomes affordable enough to actually run, which makes the more secure design testable rather than theoretical. A tenfold cost difference is worth being able to choose.

**Bad, and it must not be buried.** One instance is a **single point of failure for every outbound connection** from the private subnets — image pulls, Secrets Manager, CloudWatch. It is also a host somebody has to patch, which a managed gateway is not. For a stack destroyed between demos that is a fair trade; for anything with an SLA it is not, and the variable's description says so.

**Also.** The NAT instance is the only EC2 instance this project creates, so it reintroduces a class of maintenance — AMI drift, kernel patches — that a Fargate-only stack had entirely avoided.
