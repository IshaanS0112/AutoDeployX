# Cost breakdown

Honest monthly accounting for `ap-south-1` (Mumbai), at the traffic a portfolio
project actually sees. Two figures matter and they are very different: the cost
**running continuously**, and the cost of the way this project is meant to be
operated — **applied for a demo, destroyed afterwards**.

> Prices are the published on-demand rates for ap-south-1 as configured in this
> repo. AWS changes prices; the AWS Pricing Calculator is authoritative, this
> table is the reasoning. Verify against your own Cost Explorer after the first
> week — that number, not this table, is the one to quote.

## Running 24/7

| Resource | Config | Free tier? | ~USD/month |
|---|---|---|---|
| Application Load Balancer | 1 ALB, 2 listeners, ~0 LCU | No | **~16.00** |
| Fargate Spot compute | 2 tasks × 0.5 vCPU / 1 GB | No | **~7–9** |
| RDS PostgreSQL | 1 × db.t3.micro, 20 GB gp2, single-AZ | **Yes**, 750 hrs/mo for 12 months | 0.00 (then ~13) |
| RDS backup storage | 1-day retention, < 20 GB | Yes, up to DB size | 0.00 |
| ECR | 4 repos, last 10 images, ~2 GB | 500 MB free | ~0.10 |
| Secrets Manager | 5 secrets | No | **~2.00** |
| CloudWatch Logs | ~1 GB/mo ingest, 7-day retention | 5 GB free | 0.00 |
| CloudWatch alarms | 7 alarms | 10 free | 0.00 |
| CloudWatch dashboard | 1 | 3 free | 0.00 |
| Data transfer out | < 1 GB | 100 GB free | 0.00 |
| VPC, subnets, IGW, SGs, IAM, ECS control plane | — | Always free | 0.00 |
| **Total, in free tier** | | | **~25–27** |
| **Total, after free tier expires** | | | **~38–40** |

The ALB is the single largest line and it is unavoidable if you want a stable
public URL with health checks. Fargate Spot is the second; on-demand Fargate
would be roughly triple it.

## Applied for a demo, then destroyed

This is the intended operating mode and what `scripts/teardown.sh` exists for.

| | |
|---|---|
| Hourly rate, everything running | **~$0.033/hour** (ALB $0.0225 + Fargate Spot ~$0.010) |
| A 3-hour demo session | **~$0.10** |
| Four such sessions a month | **~$0.40** |
| Idle (destroyed) | **$0.00** — S3 state + DynamoDB lock are pennies |

The state bucket and lock table survive teardown (`prevent_destroy`), so
rebuilding is one `terraform apply` plus one pipeline run.

## What is off by default, and what it costs to turn on

**These are all built now.** Each one used to be a row in a table of things
this project had decided against, which is a claim a reader cannot check —
"I decided not to build a NAT gateway" and "I could not build a NAT gateway"
produce an identical repository.

They are now variables, every one defaulting to off, every description naming
its price (ADR 0015). The default `terraform apply` is unchanged.

Price any combination before applying it:

```bash
make cost            # production
make cost ENV=dev
```

Two rows stayed documents rather than switches, because they are a second copy
of the architecture rather than a resource behind a flag: **EKS**
(see [eks-migration.md](eks-migration.md), ~$165/month all in versus ~$48) and
**multi-region**.

| Option | Variable | Cost when on |
|---|---|---|
| Private subnets | `enable_private_subnets` | $0 alone — and non-functional alone; tasks with no route to ECR never start |
| NAT gateway | `enable_nat_gateway` | **~$32/mo each** + $0.045/GB. `single_nat_gateway` halves it and gives up cross-AZ independence |
| VPC interface endpoints | `enable_vpc_endpoints` | **~$7.20/mo per endpoint per AZ** — ~$72/mo for five across two AZs. Beats NAT only above roughly 600GB/month of egress |
| WAF | `enable_waf` | **~$8/mo** — ACL, three rule groups, plus $0.60/million requests |
| VPC flow logs | `enable_flow_logs` | **~$0.50/GB** ingested |
| ALB access logs | `enable_alb_access_logs` | **~$0.50/mo** |
| Multi-AZ RDS | `rds_multi_az` | **~2× the RDS line**; the free tier does not cover the standby |
| Performance Insights | `rds_performance_insights` | **~$2–5/mo** beyond 7-day retention |
| Enhanced monitoring | `rds_enhanced_monitoring_interval` | **~$2–5/mo**, billed per instance per minute |
| Container Insights | `enable_container_insights` | **~$3–8/mo**, not free-tier eligible |

Everything on at once, on-demand Fargate, two NAT gateways: **~$254/month**,
against **~$48/month** for the default. `make cost` prints both and the
multiple between them.

Two policy rules keep this honest, because a one-character edit here is a
$32/month change that looks like nothing in a diff:

- every billable resource must be gated behind `count` or `for_each`
- every expensive switch must default to off **and name a price in its
  description** — a rule that caught two that did not, the first time it ran

---

## The original reasoning, unchanged

Every one of these is a real architectural choice with a price attached. The
switches above exist so the choice is demonstrable; the reasoning for the
default is still the reasoning.

| Not built | Would cost | Why not |
|---|---|---|
| **NAT Gateway** | **~$32/mo** + $0.045/GB processed | The single most common way a student gets a surprise AWS bill. Private subnets need one so tasks can reach ECR and Secrets Manager. Public subnets with tightly-scoped security groups get the same isolation *for this threat model* at zero. |
| **VPC interface endpoints** (the no-NAT way to keep private subnets) | ~$7/mo each × 5 (ECR API, ECR DKR, S3, Logs, Secrets Manager) = **~$35/mo** | Same problem, same answer. |
| **EKS** | **~$73/mo** control plane alone, before any node | ECS runs the same containers with the same rollout semantics. EKS would demonstrate Kubernetes, not deployment engineering, at 3× the total cost of this stack. |
| **On-demand Fargate** instead of Spot | ~+$18/mo | Spot tasks can be reclaimed with a 2-minute warning and the service replaces them. Correct for a portfolio deployment; wrong for anything with an SLA. |
| **Multi-AZ RDS** | ~2× the RDS line | Buys failover this project has no SLA for. |
| **Container Insights** | ~$3–8/mo at this scale | Publishes custom metrics that are not free-tier eligible — it can cost more than the compute it observes. Off by default, one variable to enable. |
| **RDS Performance Insights / Enhanced Monitoring** | ~$2–5/mo | Per-instance-per-minute billing for query-level detail this workload does not generate. |
| **Multi-region** | ~2× everything | Complexity without added signal at this level. |
| **ALB access logs to S3** | ~$0.50/mo + request cost | CloudWatch already carries the request-level detail through nginx's JSON access log. |
| **VPC flow logs** | ~$0.50/GB ingested | The traffic is two tasks talking to one database. The security question flow logs answer is already answered by the security groups. |
| **WAF on the ALB** | **~$5/mo** base + per-request | More than the entire rest of the stack, for a service with no user-supplied content and no authentication surface. |
| **Customer-managed KMS keys** | ~$1/mo per key × 6 | S3, DynamoDB, ECR, CloudWatch Logs and four Secrets Manager entries are all encrypted with AWS-managed keys already. A CMK buys key rotation policy and cross-account grants, neither of which this uses. |
| **Secrets Manager rotation** | Lambda invocations, negligible | Not a cost decision — it is unbuilt work. Rotation needs a Lambda plus proof the running service picks up the new value without a restart. Listed in the limitations table rather than pretended away. |
| **CodeDeploy blue/green for ECS** | Free (the service is), but ~2× target groups and listeners | The circuit breaker already gives health-gated automatic rollback. CodeDeploy adds weighted canary shifting, which is the natural next step and genuinely harder — worth building after, not instead of. |

## What was added and costs nothing

Each of these was deliberately built within the same constraint: no custom
metric, no new billable resource.

| Added | Cost | How |
|---|---|---|
| **SLO burn-rate alarms** | **$0** | CloudWatch metric math over `RequestCount` and `HTTPCode_Target_5XX_Count`, both published free by the ALB. Alarms themselves are free up to 10 per account; this stack uses 11 with SLO alarms on, so one may fall outside — at $0.10/alarm/month. |
| **Cost Anomaly Detection** | **$0** | AWS does not charge for it. It catches the failure the fixed budgets miss: something expensive created on the 2nd, while the running total is still under $5. |
| **Image signing + SBOM** | **$0** | Sigstore's public-good instance (Fulcio, Rekor) is free. The SBOM is a build artifact and an ECR attestation — attestations are stored as ordinary images and counted by the ECR lifecycle policy. |
| **Policy as code** | **$0** | conftest and checkov both parse HCL; no AWS API call, no plan, no credentials. |
| **Drift detection** | **$0** | One `terraform plan` per week on a GitHub-hosted runner. It reads state and describes resources — no write calls. |
| **SNS encryption at rest** | **~$0** | `alias/aws/sns`, the AWS-managed key. No monthly charge, only per-request KMS calls on alarm delivery. |
| **VPC default security group locked down** | **$0** | `aws_default_security_group` with no rules adopts the group AWS already created and empties it. |

## Guardrails, and why they are the first thing applied

`terraform/modules/budgets` is applied before anything billable exists. It
creates budgets at **$5, $10 and $20**, each with two notifications:

- **ACTUAL** — spend has crossed the line
- **FORECASTED** — AWS's month-end projection has crossed it, typically days
  earlier. This is the one that actually saves money; by the time ACTUAL fires
  you have already spent it.

Plus a **$1 free-tier-breach** alarm. That one has a different job: it fires
when something that *should* be free starts charging, which usually means a
free-tier allowance ran out — the 750 RDS hours, or the 12-month window
expiring — rather than that something new was created.

**Confirm the SNS email subscription.** AWS sends a confirmation link; until it
is clicked, the CloudWatch alarms are configured correctly and will never reach
you. This is the most common reason a working alarm appears to do nothing.

## Cost checks worth running

```bash
# Month to date, by service
aws ce get-cost-and-usage \
  --time-period Start=$(date -u +%Y-%m-01),End=$(date -u +%Y-%m-%d) \
  --granularity MONTHLY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[0].Groups[?Metrics.UnblendedCost.Amount>`0.01`].[Keys[0],Metrics.UnblendedCost.Amount]' \
  --output table

# The one that must always be empty. A NAT gateway here is ~$32/mo.
aws ec2 describe-nat-gateways --query 'NatGateways[?State==`available`].NatGatewayId'

# Left running after a teardown?
aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'
```
