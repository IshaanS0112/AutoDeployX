# 0013 — Policy as code, with rules about this project

- **Status:** Accepted
- **Date:** 2026-09-20

## Context

`docs/architecture.md` claims there is no NAT gateway, that image tags are
immutable git SHAs, that the deployment circuit breaker is on, and that no
secret is ever a plaintext environment variable.

Those are claims a reader has to take on trust, and they rot the first time
somebody edits the Terraform without reading the documentation.

## Decision

Two layers. `checkov` for generic AWS misconfiguration, with every
suppression carrying a written reason in `scripts/policy-check.sh`. And
`policy/*.rego`, run with `conftest` against the HCL directly, encoding the
rules **this project** makes about itself — one rule per documented claim.

Every rule has a fixture in `policy/fixtures/` that it must reject, and
`./scripts/policy-check.sh --self-test` asserts that it does.

## Consequences

**Good.** A claim in prose rots; a claim in a policy file fails the build. The
rules need no AWS account and no `terraform plan`, so they run on a fork pull
request. The self-test is the part that matters — a policy that has never
failed is a policy nobody has verified, which is the same argument as trap 25
applied to infrastructure instead of to the manifest.

**Bad.** The rules parse HCL, so they see the source and not the plan. A value
that arrives through a variable at apply time is invisible to them:
`image_tag_mutability = var.mutability` passes a rule that
`image_tag_mutability = "MUTABLE"` fails. Plan-based policy would catch
that and needs credentials, which is the trade being made.

**Also.** 41 checkov findings are suppressed. That number is large enough to be
suspicious, which is why each one carries its argument inline rather than
sitting in a bare list — a reader can disagree with any single line.
