# 0010 — No unattended terraform apply in CI

- **Status:** Accepted
- **Date:** 2026-08-27

## Context

The natural end state of an infrastructure pipeline is GitOps: merge to main,
CI applies. Every tutorial builds toward it.

## Decision

`terraform-plan.yml` runs `fmt`, `init`, `validate`, `tflint`, the
policy rules and a real `plan` posted as a PR comment. **It never applies.**
Apply is a local, human-run operation.

## Consequences

**Good.** An unattended apply that creates an RDS instance or an ALB is a way
to wake up to a bill. Infrastructure changes still get the review gate —
the plan is on the pull request — without the account being reachable by an
automated write path.

**Bad.** Applies are manual, so the deployed infrastructure can lag main. That
is exactly the drift ADR 0013's scheduled `plan -detailed-exitcode` job
exists to surface, and it is the reason that job opens an issue rather than
fixing anything.

At a scale where a team shares the account, this decision should be revisited —
with an approval environment and a plan artifact carried from the plan job to
the apply job, so the thing applied is the thing reviewed.
