# 0021 — A read-only role for plans

- **Status:** Accepted
- **Date:** 2026-10-21
- **Source:** Read off peer repositories in this domain; see ADR 0018 for how they were chosen.

## Context

One `github-deploy` role did everything. `terraform-plan.yml` assumed it to run a plan — so a plan carried permission to update ECS services, push images and pass IAM roles, none of which a plan uses. Fork pull requests were skipped entirely, because the only role available was too powerful to hand them.

## Decision

A second role, `github-plan`, trusted by `pull_request` and `refs/heads/main` subjects, whose policy is **Describe/Get/List only** plus the state bucket. Nothing in it can create, change or delete.

`terraform-plan.yml` and `drift.yml` both moved to it. The fork-PR skip is gone: a fork can now plan, because the role it gets cannot do anything else.

Secrets Manager is in that policy for `DescribeSecret` and `ListSecrets` — the metadata a plan refreshes — and deliberately **not** `GetSecretValue`.

## Consequences

**Good.** The blast radius of the plan path went from "can deploy" to "can read". Fork contributors get a plan comment on their PR, which they could not before. A scheduled job that runs unattended every week no longer holds write permissions.

**Bad.** Two roles and two repository variables to keep in step. A missing `AWS_PLAN_ROLE_ARN` fails with an unhelpful STS error rather than a clear message.

**Also, and this is the real caution.** A fork PR's `sub` claim is still *this* repository's, so the trust policy cannot distinguish a fork from a branch. What contains a fork PR is the role's read-only **policy**, not its trust policy. Any action added to that policy is an action an arbitrary fork can invoke.
