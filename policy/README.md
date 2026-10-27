# Policy as code

Two layers, doing two different jobs.

**`checkov`** is the generic layer: a few hundred rules about AWS
misconfiguration that any account should probably satisfy. It is useful and it
is also somebody else's opinion, which is why several of its findings are
suppressed here with a written reason rather than silently.

**`policy/*.rego`** is the interesting layer: the rules *this project* makes
about itself. `docs/architecture.md` claims there is no NAT gateway, that image
tags are immutable git SHAs, that the deployment circuit breaker is on, and
that no secret is ever a plaintext environment variable. Those are claims a
reader has to take on trust — unless they are executable.

They are executed with `conftest`, which parses the HCL directly, so they run
with no AWS account and no `terraform plan`:

```bash
make policy
```

## What each rule encodes, and which claim it defends

| Rule | Defends the claim |
|---|---|
| `no_nat_gateway` | "No NAT gateway — that is ~$32/month I chose not to spend" (§2) |
| `no_public_database_port` | "5432 is reachable from the task security group and one operator address, and nothing else" (§5.3) |
| `ecr_tags_immutable` | "Roll back to a3f9c21 has a defined meaning" (trap 23) |
| `no_latest_image_tag` | "You can say exactly which commit is in production" (§5.2) |
| `circuit_breaker_enabled` | "Automatic rollback on a failed deploy" — the headline feature (§4) |
| `no_plaintext_secrets` | "Secrets are ARNs resolved at task start, never values in a task definition" (§5.3) |
| `log_retention_is_bounded` | "7-day retention; never-expire is how log bills grow quietly" (§2) |
| `secrets_have_zero_recovery_window` | Rebuild-after-teardown actually works (trap 9) |
| `ecs_service_ignores_task_definition` | "Terraform owns the shape, the pipeline owns the version" (§4.6) |
| `no_hardcoded_account_id` | State and config stay portable between accounts |
| `budgets_module_is_present` | Cost guardrails are not optional in this project (§2) |

The point is not that these rules are hard. It is that a claim in a README
rots the first time someone edits the Terraform, and a claim in a policy file
fails the build instead.

## Adding a rule

Put it in `policy/autodeployx.rego`, give it a `deny` message that says what is
wrong and why it matters, then add a fixture under `policy/fixtures/` that the
rule must reject. `scripts/policy-check.sh --self-test` runs those fixtures —
the same discipline `scripts/validate-manifest.sh --self-test` applies to the
manifest, and for the same reason.
