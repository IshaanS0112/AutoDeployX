# Architecture

## What this is

AutoDeployX takes a `git push` and turns it into a health-checked, publicly
reachable, automatically-rolled-back deployment of two real backend services on
real AWS infrastructure.

It does not deploy a hello-world. The targets are
[FinSight-360](https://github.com/IshaanS0112/FinSight-360) and
[StrategySphere-AI](https://github.com/IshaanS0112/StrategySphere-AI): FastAPI
services with a Postgres database, a React frontend, and an optional LLM
dependency. That makes the deployment non-trivial in the ways deployments are
actually non-trivial — schema on startup, secrets, a database that has to exist
before the app boots, a frontend that has to be served from the same origin as
its API.

## The one-paragraph version

```
git push (main)
     │
     ▼
┌──────────────────────────────────────────────────────────────┐
│  GitHub Actions                                              │
│                                                              │
│  plan ──► test ──► build ──► scan ──► push ──► deploy ──► smoke
│  (read     (ruff   (buildx  (Trivy,  (ECR,    (ECS      (live
│  services   +      multi-   fail on  tagged   update    URL,
│  .json)    pytest) stage,   HIGH/    :SHA)    service)  verify
│                    gha      CRITICAL)                   SHA)
│                    cache)                                    │
└───────────────────────────┬──────────────────────────────────┘
                            │  OIDC — short-lived STS creds,
                            │  no stored access key
                            ▼
┌──────────────────────────────────────────────────────────────┐
│  AWS (ap-south-1)                                            │
│                                                              │
│   Internet                                                   │
│      │                                                       │
│      ▼                                                       │
│   ┌──────── ALB ────────┐   :80 → finsight                   │
│   │  health: /api/health│   :8080 → strategysphere           │
│   └──────────┬──────────┘                                    │
│              │ target_type = ip                              │
│              ▼                                               │
│   ┌─── ECS task (awsvpc) ───────────────┐                    │
│   │  web  nginx :80 ──127.0.0.1:8000──► │                    │
│   │  api  uvicorn :8000                 │  ◄── ECR image     │
│   └──────────┬──────────────────────────┘      tagged :SHA   │
│              │                                               │
│     ┌────────┴────────┐                                      │
│     ▼                 ▼                                      │
│   RDS Postgres    Secrets Manager                            │
│   (db per svc)    (injected at task start, never in image)   │
│              │                                               │
│              ▼                                               │
│   CloudWatch — logs (7d), 7 alarms, 1 dashboard              │
└──────────────────────────────────────────────────────────────┘
              ▲
              │  Terraform — all of the above, no console clicking
```

---

## Decisions worth defending

### One manifest, read by both the pipeline and the infrastructure

`services/services.json` is the only place a service is declared. GitHub
Actions builds its matrix from it with `jq | fromJSON`; Terraform reads the
same file with `jsondecode(file(...))` and `for_each`es over it.

The alternative — a matrix in the workflow and a `for_each` list in `main.tf` —
means two lists that must be kept in sync by hand, and the failure mode is a
service that builds and pushes an image to a repository that has no ECS service
to receive it. Adding a third service here is one JSON object and nothing else.

### Two containers in one task, not two services

nginx and uvicorn run in the same ECS task. Under `awsvpc` networking every
container in a task shares one network namespace, so nginx reaches the API on
`127.0.0.1:8000`.

What this buys:

- The API port is **never** exposed outside the task. There is no security
  group rule for 8000 anywhere in this repo, because nothing outside the task
  can address it.
- Same-origin. The browser only ever talks to nginx, so CORS is not in the
  request path at all and the frontends need no build-time API URL.
- One target group, one Fargate task, half the compute bill.

What it costs, stated plainly: web and api cannot scale independently. At
`desired_count = 1` that is not a real constraint; at real traffic it would be.

`docker/docker-compose.yml` reproduces the shared namespace locally with
`network_mode: service:api`, so **one** nginx config works in both places
rather than two that drift apart.

### Public subnets, no NAT gateway

The production-correct pattern is private subnets plus a NAT gateway. A NAT
gateway is **~$32/month, forever**, more than the rest of this stack combined,
and it is the single most common way a student gets a surprise AWS bill.

So: public subnets, and the isolation comes from security groups chained by ID
rather than by CIDR —

```
internet ──► [alb SG] ──► [tasks SG] ──► [rds SG]
              :80,:8080    :80 from       :5432 from tasks SG
              from 0/0     alb SG only    + one operator /32
```

Nothing on the internet can open a connection to the database or to uvicorn.
The tradeoff is real (a compromised task has a direct egress path a NAT-less
private subnet would not give it), it is a cost decision, and it is written
down here rather than glossed over.

### Health checks: two probes, two questions

| endpoint | depth | consumer | question |
|---|---|---|---|
| `/health/live` | process only | container `HEALTHCHECK` | should this container be **restarted**? |
| `/health` | opens a DB connection | ALB target group | should this instance get **traffic**? |

Restarting a container does not fix a database outage — using the deep check
for the restart probe turns a 30-second RDS blip into a restart storm on top of
an outage. But an instance that cannot reach its database should receive no
traffic, so the ALB's probe must be the deep one.

`/health` returns **503** when unhealthy. That 503 is what the ALB sees, what
makes the target unhealthy, and therefore what the ECS circuit breaker reacts
to. A `/health` that always returns 200 makes the entire rollback mechanism
below inert.

It also returns the deployed commit SHA, which is what
`scripts/smoke-test.sh` asserts against — so a rollout that silently left the
old revision serving traffic fails the pipeline rather than passing it.

### Rollback is ECS's, not ours

```hcl
deployment_circuit_breaker {
  enable   = true
  rollback = true
}
```

ECS starts the new task alongside the old (`minimum_healthy_percent = 100`,
`maximum_percent = 200`), waits for ALB health checks, shifts traffic, drains
the old one. If the new tasks keep failing, it declares the deployment failed
and redeploys the last task definition that reached steady state. No pipeline
logic, no human.

**This is deliberately not hand-rolled**, and that is the whole relationship
with the sibling project. OpsForge Nexus implements this decision logic
explicitly — a blue-green state machine, health gating, rollback triggers,
z-score anomaly detection, an RCA pipeline — against *simulated* infrastructure,
because that project is about the reasoning. Here the platform already provides
the mechanism correctly, so reimplementing it would be a worse version of a
solved problem.

> **"How is this different from OpsForge?"**
> OpsForge is the orchestration intelligence — the state machine, the anomaly
> detection, the root-cause reasoning — built against simulated infrastructure
> so the decision logic was the whole focus. AutoDeployX is the execution
> layer: real Docker images, real GitHub Actions pipelines, real AWS defined in
> Terraform, deploying my actual services to URLs you can click. One is the
> brain, one is the hands.

### `aws ecs wait services-stable` is the wrong tool

`scripts/deploy.sh` polls `rolloutState` instead, and the reason is worth
knowing: **a service that the circuit breaker has just rolled back is
perfectly stable.** `wait services-stable` returns success for it. Using it
would report a failed deploy as a green build — the exact failure the circuit
breaker exists to catch, hidden by the tool used to watch it.

Polling `rolloutState` distinguishes `COMPLETED` from `FAILED` from
`ROLLBACK_SUCCESSFUL`.

### OIDC, and why the role ARN is not a secret

There is no `AWS_ACCESS_KEY_ID` anywhere in this repository.

GitHub mints a short-lived JWT describing the workflow run — which repo, which
ref, which environment. AWS validates it against GitHub's public keys and
checks the claims against the role's trust policy, which pins:

```
token.actions.githubusercontent.com:aud = sts.amazonaws.com
token.actions.githubusercontent.com:sub = repo:IshaanS0112/AutoDeployX:ref:refs/heads/main
                                          repo:IshaanS0112/AutoDeployX:environment:production
```

A pull request from a fork gets `repo:owner/repo:pull_request` as its subject
and **cannot assume the role at all**, regardless of what workflow file that PR
contains. There is no secret for it to exfiltrate, because there is no secret.
The role ARN is stored as a repository *variable*, not a secret, because it is
useless without a matching token.

The resulting credentials expire in an hour and are scoped by policy to this
project's four ECR repositories and two ECS services.

Note in the IAM module which actions could **not** be resource-scoped:
`ecs:RegisterTaskDefinition` and friends do not support resource-level
permissions in IAM at all. Containment there comes from `ecs:UpdateService`
being scoped — the pipeline can register a task definition, but can only point
*these* services at one. And `iam:PassRole` is scoped to exactly the two task
roles with a `PassedToService` condition, because unscoped `PassRole` is a
privilege-escalation primitive and the most commonly over-granted permission in
CI pipelines.

### Secrets

Referenced by ARN in the task definition's `secrets` block; the ECS agent
resolves them with the execution role and injects them at container start.

The value never appears in the image, in `docker history`, in
`aws ecs describe-task-definition`, or in `docker inspect`. The wrong answer to
*"how do secrets get into your container?"* is an `ENV` line in the Dockerfile,
which bakes the value into a layer anyone who can pull the image can read.

The RDS master password is generated by `random_password` and written straight
to Secrets Manager — it is never printed, never committed, never passed as an
environment variable to anything.

### Image tags are git SHAs, and ECR tags are immutable

`image_tag_mutability = "IMMUTABLE"`. A given SHA tag can never be overwritten
to point at different bytes.

This is what makes *"roll back to a3f9c21"* a meaningful instruction. With
mutable tags — and with `:latest` — the image a tag resolves to today is not
necessarily the image it resolved to when it was deployed, and neither "which
commit is in production" nor "roll back to the last good one" has a defined
answer.

### Terraform owns the shape, the pipeline owns the version

```hcl
lifecycle {
  ignore_changes = [task_definition, desired_count]
}
```

Without it, every `terraform apply` after a deploy would helpfully roll the
service back to whatever image tag was in the tfvars — silently undoing the
most recent deployment. Terraform owns infrastructure; the pipeline owns which
commit is running.

### Remote state, and why the lock table matters

S3 with versioning and a DynamoDB lock table. Local state means: one laptop, no
sharing, and — the one that actually corrupts things — no locking. Two
concurrent applies interleave writes and leave a state file describing
infrastructure that does not exist. The lock makes that impossible.

`terraform/bootstrap/` creates the bucket and table with *local* state, because
Terraform cannot create the bucket it is already trying to store state in. That
stack manages two resources, changes roughly never, and both carry
`prevent_destroy`.

---

## Known limitations

Stated here rather than discovered by an interviewer.

Several of the claims *above* this table are enforced rather than asserted —
see [`policy/`](../policy/README.md). The ones below are the gaps that remain.

| Limitation | Honest position |
|---|---|
| **HTTP by default; the TLS path is unexercised** | Built and gated on `domain_name` + `route53_zone_id` ([ADR 0011](adr/0011-optional-tls-and-host-based-routing.md)). It validates and passes the policy rules, but it has not been applied against a real certificate — so the honest claim is "written", not "proven". |
| **Port-based routing** (`:80` / `:8080`) is still the default | Host-based routing exists and turns on with the same two variables as TLS. The default stays port-based because the prerequisite is a domain and not every reader has one. |
| **Two environments, only one exercised** | `dev` and `production` are separate tfvars files and separate state keys ([terraform/envs/](../terraform/envs/README.md)). `dev` has never been applied. The claim is that the *shape* is there, not that a promotion flow has been rehearsed. |
| **`desired_count = 1`** | No redundancy. A Spot reclaim or a failed task is a brief outage. It is one variable, and it doubles the compute line. |
| **Load test written, never run against a deployment** | `load/smoke.js` has real thresholds — p95 under 2s, error rate under 1% — and `docs/load-test-report.md` is generated from actual runs. It is empty. Until there is a row in it, "not load tested" is still the correct answer. |
| **Public subnets** | Cost decision, above. Private subnets + NAT is the production-correct pattern at ~$32/month. |
| **Public RDS endpoint** | SG-restricted to the task SG and one operator `/32`. Exists so the one-time database bootstrap does not need a bastion — another ~$8/month. |
| **ECS, not Kubernetes** | Deliberate. EKS control plane is ~$73/month and demonstrates Kubernetes rather than deployment engineering. |
| **`create_all` on startup in FinSight** | Inherited from the service. StrategySphere has since adopted Alembic, with a migration round-trip in its own CI — so the gap is now one service, not two. |
| **Signature verification is pipeline-side only** | Images are signed and the deploy job verifies both the signature and the certificate identity, but nothing stops someone with ECR write access and `ecs:UpdateService` deploying an unsigned image out of band. That needs an admission controller and ECS does not have one ([ADR 0014](adr/0014-keyless-signing-and-sbom.md)). |
| **Policy rules parse HCL, not a plan** | A value that arrives through a variable at apply time is invisible to them: `image_tag_mutability = var.mutability` passes a rule that the literal `"MUTABLE"` fails. Plan-based policy catches that and needs credentials ([ADR 0013](adr/0013-policy-as-code-with-project-specific-rules.md)). |
| **41 checkov findings suppressed** | That number is large enough to deserve suspicion. Each carries its argument inline in `scripts/policy-check.sh` rather than sitting in a bare list, so any single one can be disagreed with. Three findings were fixed rather than suppressed: the VPC default security group, SNS encryption at rest, and AZ pinning. |
| **No secrets rotation** | Secrets Manager supports automatic rotation and this does not use it. It needs a rotation Lambda plus proof the running service picks up the new value without a restart, which is a real piece of work rather than a flag. |
| **Lint gate off for StrategySphere** | That repo had no ruff config and its CI never linted, so its tree does not satisfy one. `patches/strategysphere-lint-parity.patch` fixes it; the manifest records the gate as off until then rather than failing every deploy on a standard the repo never adopted. |


---

## Decision records

The reasoning above is summarised. [`docs/adr/`](adr/README.md) has one record
per decision, each with the alternative that was rejected and the cost of
having rejected it — a decision with no cost is a preference, not a decision.

## Verification

"Done" means a command exits zero.

| Gate | Command | Covers |
|---|---|---|
| G1 | `hadolint --failure-threshold warning docker/*` + `make up` | Images build, compose stack answers |
| G2 | `make lint` | actionlint, shellcheck, hadolint, manifest schema |
| G3 | `make tf-lint` | `fmt -check`, `validate` (root and bootstrap), `tflint --recursive` |
| G4 | `bash -n scripts/*.sh` | Script syntax |
| G5 | `git apply --check` against a fresh clone, then that repo's suite | `patches/` still apply and leave the target green |
| G6 | `scripts/smoke-test.sh` against the live URL | The deployed commit is the one just deployed |
| G7 | The deliberate-break drill in [runbook.md](runbook.md) | Rollback actually rolls back |
| Policy | `make policy` | conftest + checkov, both with `--self-test` first |

G1–G4 and the policy gate run with no AWS account. G5 needs network access to
the target repositories. **G6 and G7 need a live deployment. Both have been run
against one: the smoke test passed on the live URL, and the deliberate-break
drill rolled back as designed.**
