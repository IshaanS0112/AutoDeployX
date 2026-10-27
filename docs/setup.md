# Setup

End to end, on a fresh AWS account. Roughly 45 minutes, most of it waiting for
RDS.

## Prerequisites

```bash
aws --version          # v2
terraform -version     # >= 1.6
docker --version
jq --version
psql --version         # macOS: brew install libpq && brew link --force libpq
gh --version           # optional, for triggering workflows from the CLI
```

For the quality gates, which run with no AWS account at all:

```bash
brew install shellcheck hadolint actionlint conftest
brew install terraform-linters/tflint/tflint
pipx install checkov    # PEP 668 blocks a bare pip install on macOS
brew install k6         # optional, for the load test
```

`terraform` is no longer in Homebrew core — it lives in HashiCorp's tap:
`brew install hashicorp/tap/terraform`.

Then, before touching AWS:

```bash
make check      # lint + terraform gates
make policy     # conftest + checkov
```

`aws sts get-caller-identity` must return your account. Repos checked out side
by side:

```
projects/
  AutoDeployX/
  FinSight-360/
  StrategySphere-AI/
```

---

## 0. Budget alarms, before anything else

Do this in the console now, not later, and not only in Terraform. Terraform
creates budgets in step 3 — but between account creation and step 3 you are
unprotected, and that is exactly the window in which people click something
expensive.

**Billing → Budgets → Create budget → Cost budget → $5/month**, with an email
notification at 100% actual *and* 100% forecasted.

Also enable **Billing → Billing preferences → Receive Free Tier alerts**.

---

## 1. Create the Terraform state backend

```bash
cd AutoDeployX
make state                 # or: make state ENV=dev
```

Creates the S3 bucket (versioned, encrypted, public access blocked) and the
DynamoDB lock table, then writes `terraform/backend.production.hcl`. Both carry
`prevent_destroy` — teardown never touches them.

The bucket and table are created **once per AWS account** and shared by every
environment; environments are separated by state key, not by bucket. Running
this again for `dev` finds them already there and only writes a second backend
file.

Note the two names it prints; they become GitHub repository variables in step 5.

---

## 2. Configure

```bash
cp terraform/envs/production.tfvars.example terraform/envs/production.tfvars
curl -s ifconfig.me            # your public IP
```

Edit `terraform/envs/production.tfvars`:

- `operator_cidr` — `"<that IP>/32"`. **Not** `0.0.0.0/0`.
- `budget_notification_email` — a real address you read.

Real `.tfvars` files are gitignored; only the `.example` templates are
committed. The Anthropic key does not go in either:

```bash
export TF_VAR_anthropic_api_key="sk-ant-..."     # optional
```

Optional because both services fall back to a deterministic template for
narration — every ratio, Z-score and strategy score is computed identically
without it.

---

## 3. Apply

```bash
make init
make budgets         # cost alarms ALONE, first — nothing else is free
make plan            # read it
make apply
```

`make budgets` is `terraform apply -target=module.budgets`. It is separated on
purpose: the window between "an account exists" and "budget alarms exist" is
exactly when an expensive mistake goes unnoticed.

The full apply is ~10 minutes; RDS is most of it.

**Optional, and this is where TLS turns on.** Set `domain_name` and
`route53_zone_id` in the tfvars and the stack comes up on HTTPS with each
service at `<key>.<domain>`, `:80` redirecting, and the `:8080` oddity gone.
Leave them empty for plain HTTP on per-service ports.

**Expected at this point:** the ECS services exist and their tasks are failing
with `CannotPullContainerError`. Nothing has pushed an image yet. That is
normal — step 6 fixes it.

Outputs you need:

```bash
terraform output service_urls
terraform output github_deploy_role_arn
terraform output dashboard_url
```

**Confirm the SNS subscription email.** Until you click the link, the
subscription sits in `PendingConfirmation` and the CloudWatch alarms are
correctly configured and will never reach you. This is the single most common
reason a working alarm appears to do nothing.

**Also confirm the Cost Anomaly Detection subscription**, which arrives as a
separate email.

---

## 4. Create the databases

```bash
cd .. && ./scripts/init-databases.sh
```

Creates one database and one least-privilege role per service, using the
passwords Terraform already generated in Secrets Manager. Idempotent — re-run
it after any teardown/rebuild.

If it cannot connect: your IP changed. `curl -s ifconfig.me`, update
`operator_cidr`, `terraform apply`, retry.

---

## 5. Wire up GitHub

**Repository variables** (Settings → Secrets and variables → Actions →
Variables). Variables, not secrets — none of these are sensitive:

| Variable | Value |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | `terraform output -raw github_deploy_role_arn` |
| `ECS_CLUSTER` | `terraform output -raw ecs_cluster_name` |
| `TF_STATE_BUCKET` | from step 1 |
| `AWS_PLAN_ROLE_ARN` | `terraform output github_plan_role_arn` — the READ-ONLY role pull requests and the drift check assume |
| `OPERATOR_CIDR` | same as tfvars |
| `BUDGET_EMAIL` | same as tfvars |

**Environment** (Settings → Environments → New environment → `production`).
The name must match — the IAM trust policy allows
`repo:IshaanS0112/AutoDeployX:environment:production`, so protection rules you
set here are a real control, not just a badge. Add a required reviewer if you
want manual approval before every production deploy.

There is **no** AWS secret to add. That is the point.

---

## 6. Apply the service patches

**Order matters for StrategySphere.** Its two patches are sequential, not
independent: lint-parity reformats most of the tree, and the health patch is
generated against the already-formatted file. The other way round fails on
context.

```bash
cd ../FinSight-360
git apply --check ../AutoDeployX/patches/finsight-health-endpoint.patch   # dry run first
git apply ../AutoDeployX/patches/finsight-health-endpoint.patch
git commit -am "health: check the database and report the deployed commit"
git push

cd ../StrategySphere-AI
git apply ../AutoDeployX/patches/strategysphere-lint-parity.patch      # 1. the standard
git commit -am "lint: adopt ruff, matching FinSight-360"
git apply ../AutoDeployX/patches/strategysphere-health-endpoint.patch  # 2. conforms to it
git commit -am "health: check the database and report the deployed commit"
git push
```

Run each repo's own suite before pushing — `git apply` succeeding means the
context matched, not that the result works:

```bash
cd backend && python -m pytest -q      # 245 FinSight / 226 StrategySphere
```

Then set `checks.lint` to `true` for `strategysphere` in
`services/services.json`. See `patches/README.md` for what each one does and
why.

**If `git apply --check` fails,** the target repo has moved past the patch.
That is gate G5 telling you something true: regenerate the patch against the
current HEAD rather than forcing it with `--3way`.

---

## 7. First deploy

```bash
cd ../AutoDeployX
./scripts/seed-images.sh
```

Builds and pushes the first images locally and deploys them, so you find out
whether the infrastructure works without waiting for a push-to-main cycle.

Then:

```bash
terraform -chdir=terraform output -json service_urls | jq
curl -s http://<alb-dns>:80/api/health | jq
```

You should see `{"status":"healthy","checks":{"database":"ok"},"commit":"<sha>"}`.

**Open the URL in a browser.** That is the thing this project exists to
produce.

---

## 8. Hand deployment over to the pipeline

```bash
git push origin main
```

Watch Actions. From here on, `seed-images.sh` is never needed again.

---

## 9. Measure the image sizes

```bash
./scripts/measure-image-size.sh ../FinSight-360 finsight
```

Writes to `docs/image-size-report.md`. **Put those numbers on the resume, not
estimated ones** — every pipeline run also records them in the job summary.

---

## 10. Measure it under load

```bash
make load URL="$(terraform -chdir=terraform output -json service_urls | jq -r .finsight)"
```

Appends a row to `docs/load-test-report.md` with real rps, error rate and p50 /
p95 / p99. Until that file has a row in it, the correct answer to "how does it
perform under load" is "I do not know" — and that is what the limitations table
says.

The thresholds in `load/smoke.js` are the same numbers as the CloudWatch
latency alarm, so a passing load test and a quiet alarm mean the same thing. A
threshold breach exits non-zero; that is a result, not a broken script.

---

## 11. Prove the rollback works

The most valuable thing in the demo. Full procedure in
[`runbook.md`](runbook.md#deliberately-breaking-a-deploy-to-prove-the-rollback-works):
push a commit whose `/health` returns 503, watch ECS fail the rollout and
restore the previous task definition, and `curl` the URL throughout to show it
never stops answering.

Record it.

---

## 12. Tear down

```bash
make destroy               # or: make destroy ENV=dev
```

It prints what will be destroyed and requires you to type
`destroy production` — the environment name, not a generic word, because
typing "destroy" while looking at the wrong terminal is a mistake everyone
makes once.

~$0.033/hour running, $0.00 destroyed. Rebuild is `make apply` + `make seed`.

Budget alarms are destroyed too. If you are tearing down *because* of cost,
put them back on their own:

```bash
make budgets
```

---

## Common first-run problems

| Symptom | Cause |
|---|---|
| `EntityAlreadyExists: OIDC provider` | The account already has a GitHub OIDC provider — there can be only one per issuer. Set `create_oidc_provider = false` and pass `existing_oidc_provider_arn`. |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | The `sub` claim does not match `github_allowed_refs`. Check owner, repo and branch spelling — it is nearly always a typo here. |
| `CannotPullContainerError` | No image pushed yet. Expected before step 7. |
| `unable to pull secrets` | Secrets were recreated with new ARNs. `terraform apply` again. |
| `a secret with this name is scheduled for deletion` | A rebuild after teardown hit Secrets Manager's recovery window. Every secret here sets `recovery_window_in_days = 0` precisely to avoid this; if you see it, something is creating a secret outside this stack. |
| `Error: Backend configuration changed` | You switched environments without `-reconfigure`. `make init ENV=<env>` passes it. Do **not** accept Terraform's offer to migrate state — that copies one environment's state onto another's key. |
| `cosign verify` fails in the deploy job | The image in ECR was not pushed by this pipeline. That is the check working. |
| Alarms never fire | The SNS subscription is still `PendingConfirmation`. Check your inbox, including spam. |
| `init-databases.sh` hangs | Your public IP changed. |
| Alarms never fire | The SNS subscription email was never confirmed. |
