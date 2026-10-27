# 0006 — Terraform owns the shape, the pipeline owns the version

- **Status:** Accepted
- **Date:** 2026-08-25

## Context

Terraform creates the ECS service with a task definition. The pipeline then
deploys new revisions of that task definition. Both now have an opinion about
which image is running.

## Decision

`aws_ecs_service` declares
`lifecycle { ignore_changes = [task_definition, desired_count] }`.

## Consequences

**Good.** Terraform owns infrastructure; the pipeline owns which commit runs.
Without this, every `terraform apply` after a deploy helpfully rolls the
service back to whatever image tag is in the tfvars — silently undoing the
most recent deployment, with a plan that looks routine.

**Bad.** `terraform plan` no longer tells you what is deployed. The answer to
that question lives in `/health`, in ECR, and in the pipeline's run history.
This is enforced by a policy rule (`ecs_service_ignores_task_definition`) so
that removing the lifecycle block fails the build rather than quietly
reintroducing the bug.
