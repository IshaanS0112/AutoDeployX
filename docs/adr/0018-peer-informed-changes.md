# 0018 — What was taken from other repositories, and what was not

- **Status:** Accepted
- **Date:** 2026-10-21

## Context

A survey of GitHub for comparable work — Terraform + ECS Fargate + GitHub
Actions reference platforms — to find practices this project was missing.

**The first finding was about the sample itself.** The repositories that match
this niche have **0 to 10 stars**. They are other people's portfolio projects
at the same level as this one, not authoritative references. There is no
canonical high-star repository in this exact space to copy from; the genuinely
authoritative sources are AWS's own ECS best-practices guidance and
`terraform-aws-modules`.

That matters for how the survey was used. Reading peers is useful for finding
*specific techniques you had not considered*. It is not a reason to adopt an
architecture wholesale, and "three other repos do it" is not evidence that
something is right.

Two were read closely:
[mhkhan01/aws-platform-reference](https://github.com/mhkhan01/aws-platform-reference)
and
[jdgermosen/aws-ecs-platform-terraform](https://github.com/jdgermosen/aws-ecs-platform-terraform).

## Decision

**Adopted — five changes, each with its own record:**

| Change | ADR | Why it survived review |
|---|---|---|
| ARM64 / Graviton Fargate | [0019](0019-arm64-fargate.md) | ~20% cheaper for identical work |
| Target-tracking autoscaling | [0020](0020-autoscaling-with-a-connection-ceiling.md) | Closes a documented weakness |
| Split plan / apply IAM roles | [0021](0021-split-plan-and-apply-roles.md) | A plan reads; it never needed write |
| S3-native state locking | [0022](0022-s3-native-state-locking.md) | Deletes a resource and an IAM grant |
| NAT instance mode | [0023](0023-nat-instance-mode.md) | $3/month against $33, fits the cost thesis |

**Rejected — each would overturn a decision this project has reasoning for:**

| Seen in peers | Why not |
|---|---|
| Customer-managed KMS keys throughout | ~$1/month per key × 6, to replace AWS-managed keys that already encrypt at rest (ADR 0015) |
| Container Insights on by default | Publishes custom metrics that are not free-tier eligible and can exceed the compute they observe |
| Multi-AZ RDS by default | Already a switch; defaulting it on doubles the RDS line for failover this project makes no SLA about |
| CI applies Terraform on `main` | Directly reverses [ADR 0010](0010-no-unattended-terraform-apply.md). An unattended apply that creates an RDS instance is how you wake up to a bill |
| A Kubernetes track | Reverses [ADR 0009](0009-ecs-not-eks.md); costed in [eks-migration.md](../eks-migration.md) at ~$165/month against ~$48 |

## Consequences

**Good.** Five real improvements to IAM, compute, networking and state, none
of which required abandoning a documented decision. The rejections are now
written down with the specific peer practice they decline, which is a stronger
position than never having looked.

**Bad.** Reading peers at your own level has a ceiling. None of these
repositories demonstrated anything about operating a service under real
traffic, because none of them is under real traffic either — and neither is
this one. The gap that matters most (G6 and G7, a live deployment and a
rehearsed rollback) is not one a survey can close.
