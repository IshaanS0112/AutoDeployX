# 0008 — No NAT gateway; public subnets with chained security groups

- **Status:** Accepted; amended 2026-09-20 — the NAT path is now built and gated, see below
- **Date:** 2026-08-26

## Context

Fargate tasks need to reach ECR and Secrets Manager. The textbook design puts
them in private subnets, which then need a NAT gateway (~$32/month plus
$0.045/GB) or five VPC interface endpoints (~$7/month each) to get out.

The entire rest of this stack costs about $0.03/hour.

## Decision

Tasks run in public subnets with `assign_public_ip = true`. Isolation comes
from three security groups chained **by ID, not CIDR**: internet to the ALB
group, ALB group to the tasks group, tasks group to the RDS group. The
database accepts 5432 from the tasks security group and one operator /32.

## Consequences

**Good.** Zero cost for the same practical isolation at this threat model.
Nothing can reach a task except through the ALB, and nothing can reach the
database except a task or the operator.

**Bad, and this is the honest part.** Private subnets plus NAT is the
production-correct pattern, and the reason is not the security group — it is
that a public IP is one misconfigured security group away from being reachable,
and a private subnet is not. This is a cost decision with a real security
consequence, documented rather than dressed up.

The tradeoff is enforced both ways: a policy rule fails the build if a NAT
gateway appears (the claim stops being true) and another fails it if 5432 is
ever opened to `0.0.0.0/0` (the justification stops being true).


## Amendment, 2026-09-20

The NAT gateway, private subnets and VPC interface endpoints are now **built**,
behind `enable_private_subnets`, `enable_nat_gateway` and
`enable_vpc_endpoints`. All three default to false, and the default apply is
unchanged.

The decision did not change. What changed is that the decision is now
demonstrable: `make cost` prices the private topology at roughly $114/month
against $48 for the default, and one variable moves between them.

The policy rule moved with it. It used to assert that no `aws_nat_gateway`
resource existed, which stopped being the claim the moment the resource was
written. It now asserts two narrower things that are still true:

- every billable resource is **gated** behind `count` or `for_each`, so nothing
  expensive is created unconditionally, and
- every expensive switch **defaults to off**, and its variable description
  **names a price** — a rule that immediately caught two descriptions that did
  not.

That second rule is the one that protects the cost story now. Building the
expensive options as variables is only safe while their defaults are false: a
single edit turning `default = false` into `default = true` would move this
stack an order of magnitude and nothing else in the repository would notice.
