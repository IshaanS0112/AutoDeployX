# Runbook

What to do when a deploy fails, written for the version of you that is looking
at a red pipeline ten minutes before a demo.

Every command assumes:

```bash
export CLUSTER=autodeployx-production
export SERVICE=finsight            # or strategysphere
export AWS_REGION=ap-south-1
```

---

## First: is the site up?

The whole point of the circuit breaker is that a failed deploy is not an
outage. Check before you debug.

```bash
curl -s http://<alb-dns>:80/api/health | jq
```

- **`{"status":"healthy", "commit":"<old sha>"}`** — the site is fine, the
  previous version is serving traffic, the rollback worked. You have time.
  Debug at your own pace.
- **`{"status":"unhealthy","checks":{"database":"unreachable"}}`** — the app is
  running but cannot reach RDS. Go to *Database unreachable*.
- **connection refused / 503 from the ALB** — no healthy targets at all. Go to
  *No healthy targets*.

---

## Deploy failed — what did ECS actually decide?

```bash
aws ecs describe-services --cluster "$CLUSTER" --services "${CLUSTER}-${SERVICE}" \
  --query 'services[0].deployments[].[status,rolloutState,rolloutStateReason,runningCount,desiredCount,failedTasks]' \
  --output table
```

`rolloutState` is the field that matters:

| value | meaning | what to do |
|---|---|---|
| `COMPLETED` | new revision is live | nothing — the pipeline failed on something after the rollout, probably the smoke test |
| `IN_PROGRESS` | still rolling | wait; the pipeline gives it 10 minutes |
| `FAILED` | circuit breaker tripped | rollback is underway — read on |
| `ROLLBACK_IN_PROGRESS` / `ROLLBACK_SUCCESSFUL` | previous revision is being restored | **this is the system working.** Find out why the new one was bad |

Then the service event log, which is where ECS says what it did in English:

```bash
aws ecs describe-services --cluster "$CLUSTER" --services "${CLUSTER}-${SERVICE}" \
  --query 'services[0].events[0:15].[createdAt,message]' --output table
```

---

## Why did the new task fail?

### 1. Find the stopped task and its stop reason

```bash
TASK=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "${CLUSTER}-${SERVICE}" \
        --desired-status STOPPED --query 'taskArns[0]' --output text)

aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$TASK" \
  --query 'tasks[0].[stoppedReason,containers[].[name,lastStatus,exitCode,reason]]' --output json
```

`stoppedReason` names the failure class directly. The common ones:

| stoppedReason / container reason | cause | fix |
|---|---|---|
| `CannotPullContainerError` | the image tag is not in ECR | expected on the very first apply — nothing has been pushed yet. Run `./scripts/seed-images.sh` or push to main. Otherwise check the tag matches what the pipeline pushed |
| `ResourceInitializationError: unable to pull secrets` | the task execution role cannot read a Secrets Manager ARN | the secret was recreated with a new ARN. Re-run `terraform apply` so the task definition and the IAM policy pick it up |
| `Essential container in task exited`, exitCode 1 | the app crashed on startup | logs, below |
| `Task failed ELB health checks` | app started but `/api/health` never returned 200 | almost always the database — next section |
| `OutOfMemoryError` | container exceeded its memory | raise `task_memory` in `services/services.json` |
| Spot interruption message | FARGATE_SPOT reclaim | not a bug. ECS replaces the task. Set `use_fargate_spot = false` before a demo if you cannot tolerate it |

### 2. Read the logs

```bash
aws logs tail "/ecs/${CLUSTER}/${SERVICE}" --since 20m --follow
aws logs tail "/ecs/${CLUSTER}/${SERVICE}" --since 20m \
  --filter-pattern '?ERROR ?Traceback ?CRITICAL'
```

Streams are prefixed `api/` and `web/`, so you can tell uvicorn from nginx.

### 3. Get a shell in a running task

`enable_execute_command` is on. This needs the Session Manager plugin installed
locally.

```bash
TASK=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "${CLUSTER}-${SERVICE}" \
        --desired-status RUNNING --query 'taskArns[0]' --output text)

aws ecs execute-command --cluster "$CLUSTER" --task "$TASK" \
  --container api --interactive --command "/bin/sh"
```

Inside:

```sh
python -c "import os; print(os.environ['DATABASE_URL'][:40])"   # is the secret injected?
python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/health').read())"
```

---

## Database unreachable

`/health` returning `{"checks":{"database":"unreachable"}}`. In order of
likelihood:

1. **The database or role does not exist.** `scripts/init-databases.sh` has not
   been run since the last teardown. Run it. It is idempotent.
2. **The secret is stale.** A destroy/apply cycle regenerates the password. The
   task definition references the secret by ARN and picks up the new value on
   the next deploy — but the *Postgres role* still has the old password until
   `init-databases.sh` runs again. Run it.
3. **Security group.** The task SG must be allowed on 5432 in the RDS SG:
   ```bash
   aws rds describe-db-instances --db-instance-identifier "${CLUSTER}-postgres" \
     --query 'DBInstances[0].[DBInstanceStatus,Endpoint.Address,VpcSecurityGroups]'
   ```
4. **RDS is still creating.** First apply takes ~8 minutes. `DBInstanceStatus`
   must be `available`.

Test the path yourself (requires your IP in `operator_cidr`):

```bash
PGPASSWORD=$(aws secretsmanager get-secret-value \
  --secret-id "${CLUSTER}/rds/master" --query SecretString --output text | jq -r .password) \
psql -h $(terraform -chdir=terraform output -raw rds_endpoint) -U adxadmin -d postgres -c '\l'
```

If that hangs, your public IP changed. `curl -s ifconfig.me`, update
`operator_cidr` in `terraform.tfvars`, re-apply.

---

## No healthy targets

```bash
TG=$(terraform -chdir=terraform output -json | jq -r ".deployed_services.value.${SERVICE}.service" >/dev/null; \
     aws elbv2 describe-target-groups --query "TargetGroups[?contains(TargetGroupName,'${SERVICE:0:1}')].TargetGroupArn" --output text)
aws elbv2 describe-target-health --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason,TargetHealth.Description]' --output table
```

| Reason | Meaning |
|---|---|
| `Target.ResponseCodeMismatch` | `/api/health` answered with something other than 200 — usually 503, meaning the DB check failed |
| `Target.Timeout` | nginx did not answer in 5s. The `api` container is probably not up, so nginx's proxy_pass is hanging |
| `Target.FailedHealthChecks` | generic; go to the logs |
| `Elb.RegistrationInProgress` | normal for ~30s after a deploy |

---

## Rolling back on purpose

The circuit breaker handles a deploy that *fails*. This is for a deploy that
succeeded and turned out to be wrong.

**GitHub UI:** Actions → Rollback → Run workflow → service + the 8-char SHA.

**CLI:**

```bash
gh workflow run rollback.yml -f service=finsight -f sha=a3f9c21b -f reason="bad migration"
```

**No pipeline available** (GitHub down, or you are on a phone hotspot):

```bash
SERVICE_KEY=finsight IMAGE_TAG=a3f9c21b CLUSTER=$CLUSTER AWS_REGION=$AWS_REGION \
  ./scripts/deploy.sh
```

Which SHAs can you roll back to? The ECR lifecycle policy keeps the last 10:

```bash
aws ecr describe-images --repository-name "autodeployx/${SERVICE}-api" \
  --query 'sort_by(imageDetails,&imagePushedAt)[-10:].[imageTags[0],imagePushedAt]' --output table
```

**Then revert the commit in git.** A rollback changes what is running; it does
not change what `main` points at. The next push redeploys the problem.

---

## Deliberately breaking a deploy, to prove the rollback works

This is the strongest thing in the demo. Practise it.

In the service repo, on a branch, make `/health` fail:

```python
@app.get("/health")
def health(response: Response) -> dict[str, object]:
    response.status_code = 503
    return {"status": "deliberately broken"}
```

Push to `main`. Then watch:

```bash
watch -n 5 'aws ecs describe-services --cluster '"$CLUSTER"' --services '"${CLUSTER}-${SERVICE}"' \
  --query "services[0].deployments[].[status,rolloutState,runningCount]" --output table'
```

Expected sequence, about 4–6 minutes end to end:

1. New task starts alongside the old one (`maximumPercent = 200`)
2. ALB health checks fail — 3 × 15s
3. ECS marks the deployment `FAILED`, circuit breaker trips
4. `ROLLBACK_IN_PROGRESS` → `ROLLBACK_SUCCESSFUL`
5. **The old version is still serving the whole time.** `curl` the URL
   throughout — it never stops answering
6. The pipeline's deploy job goes red with `result=rolled_back`

Then revert the commit.

---

## Cost emergency

```bash
./scripts/teardown.sh --yes
terraform -chdir=terraform apply -target=module.budgets   # keep the alarms
```

Then confirm nothing is still billing — see `docs/cost-breakdown.md`.

---

## Terraform state is locked

Usually a previous run that was killed mid-apply.

```bash
terraform -chdir=terraform force-unlock <LOCK_ID>
```

The ID is in the error message. **Only** do this once you are certain no other
apply is running — that is the exact scenario the lock exists to prevent.

---

## A drift issue was opened

`drift.yml` runs `terraform plan -detailed-exitcode` weekly. Exit code 2 means
reality and state have diverged; the workflow opens one issue labelled `drift`,
comments on it while the drift persists, and closes it when the plan comes back
clean.

Read the plan in the issue first. It is almost always one of three things:

| What the plan shows | What happened | What to do |
|---|---|---|
| A change to something you recognise | Someone changed it in the console | Move the change into Terraform, or revert it in the console. Do not just apply — find out why it was changed by hand. |
| A change to an attribute you never set | An AWS-side default moved | Usually the right fix is `ignore_changes` with a comment saying why, the same way `engine_version` is handled on RDS. |
| A resource being **created** | It was deleted outside Terraform | Check what depended on it before applying. A deleted target group means the listener is also broken. |

Exit code **1** is different and the workflow fails loudly for it: the plan did
not run at all. That is a broken configuration or broken credentials, not
drift.

Between demos this stack is destroyed, so the workflow checks for an active
ECS cluster first and exits quietly if there is none. A destroyed stack is not
drift, and reporting it as drift every Monday is how a useful alert becomes
noise.

---

## The policy gate failed

```bash
make policy
```

Two layers, and which one failed matters.

**`conftest` failed** — a rule in `policy/autodeployx.rego` fired. Each of
those rules corresponds to a claim in `docs/architecture.md`. The message names
the resource and says which claim it breaks. Two possibilities:

- The change is wrong. Fix the Terraform.
- The claim has changed on purpose. Then update the documentation and the ADR
  *and* delete the rule, in the same commit. A rule that is suppressed without
  the documentation changing is worse than no rule, because the documentation
  now lies and nothing says so.

**`checkov` failed** — a generic AWS rule fired on something new. Decide
whether it is worth fixing or worth suppressing, and if suppressing, add it to
`CHECKOV_SKIPS` **with the reason written inline**. Every existing suppression
carries its argument; a bare check ID in that list is a gap in the reasoning,
not a gap in the tooling.

To check that the rules themselves still work:

```bash
./scripts/policy-check.sh --self-test
```

That feeds every rule a fixture it must reject. If a fixture is accepted, the
rule has been broken — which is the failure mode a policy file has, and the
reason the self-test exists.

---

## `cosign verify` failed in the deploy job

The image in ECR was not signed by this pipeline. **That is the check working,
not a bug in it.**

The verification checks the certificate *identity*, not just that a signature
exists — "it has a valid signature" only means somebody signed it, whereas
"the certificate says `github.com/<owner>/<repo>`, issued by GitHub's OIDC
provider" means this pipeline signed it.

Legitimate causes:

| Cause | Fix |
|---|---|
| The image was pushed by `seed-images.sh`, which runs locally and does not sign | Expected for the bootstrap image only. The first pipeline deploy replaces it. |
| The repository was renamed | The certificate identity regex no longer matches. Update it. |
| The build job's signing step was skipped or failed | Look at the build job. Do not bypass the verify step. |

If it is none of those, somebody pushed an image into your registry. Do not
deploy it.
