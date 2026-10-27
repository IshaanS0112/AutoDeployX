# Architecture decision records

One file per decision that was not obvious, with the alternative that was
rejected and the cost of having rejected it.

The format is deliberately short. An ADR that takes twenty minutes to write
does not get written, and the value here is entirely in the record existing at
the moment the decision was made — not in its prose.

Each record states its **consequence** as well as its rationale, because a
decision with no cost is not a decision, it is a preference.

| # | Decision | Status |
|---|---|---|
| [0001](0001-one-manifest-for-pipeline-and-infrastructure.md) | One manifest read by both the pipeline and the infrastructure | Accepted |
| [0002](0002-two-containers-in-one-ecs-task.md) | nginx and uvicorn in one ECS task, not two services | Accepted |
| [0003](0003-alb-routes-by-listener-port.md) | ALB routes by listener port, not path | Superseded in part by [0011](0011-optional-tls-and-host-based-routing.md) |
| [0004](0004-two-health-probes.md) | Two health probes, shallow and deep | Accepted |
| [0005](0005-poll-rollout-state.md) | Poll `rolloutState`, never `aws ecs wait services-stable` | Accepted |
| [0006](0006-terraform-owns-shape-pipeline-owns-version.md) | Terraform owns the shape, the pipeline owns the version | Accepted |
| [0007](0007-construct-arns-to-break-the-iam-ecs-cycle.md) | Construct ARNs rather than reference them | Accepted |
| [0008](0008-no-nat-gateway.md) | No NAT gateway; public subnets with chained security groups | Accepted, amended by [0015](0015-expensive-options-as-gated-switches.md) |
| [0009](0009-ecs-not-eks.md) | ECS Fargate, not EKS | Accepted |
| [0010](0010-no-unattended-terraform-apply.md) | No unattended `terraform apply` in CI | Accepted |
| [0011](0011-optional-tls-and-host-based-routing.md) | TLS and host-based routing, gated on a domain | Accepted |
| [0012](0012-slo-burn-rate-over-fixed-thresholds.md) | Error-budget burn rate alongside fixed thresholds | Accepted |
| [0013](0013-policy-as-code-with-project-specific-rules.md) | Policy as code, with rules about this project | Accepted |
| [0014](0014-keyless-signing-and-sbom.md) | Keyless image signing and SBOM attestation | Accepted |
| [0015](0015-expensive-options-as-gated-switches.md) | Build the expensive options, default them off | Accepted |
| [0016](0016-migrations-as-a-separate-pre-rollout-task.md) | Schema migrations as a separate task, before the rollout | Accepted |
| [0017](0017-connection-budget-and-graceful-shutdown.md) | Size the connection pool against the instance, and drain in order | Accepted |
| [0018](0018-peer-informed-changes.md) | What was taken from other repositories, and what was not | Accepted |
| [0019](0019-arm64-fargate.md) | ARM64 Fargate instead of X86_64 | Accepted |
| [0020](0020-autoscaling-with-a-connection-ceiling.md) | Autoscaling, bounded by the connection budget | Accepted |
| [0021](0021-split-plan-and-apply-roles.md) | A read-only role for plans | Accepted |
| [0022](0022-s3-native-state-locking.md) | S3-native state locking, no DynamoDB | Accepted |
| [0023](0023-nat-instance-mode.md) | A NAT instance mode at a tenth the cost | Accepted |
