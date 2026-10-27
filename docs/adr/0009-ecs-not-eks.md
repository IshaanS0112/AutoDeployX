# 0009 — ECS Fargate, not EKS

- **Status:** Accepted
- **Date:** 2026-08-26

## Context

Kubernetes is what most job descriptions list. EKS would demonstrate it.

## Decision

ECS Fargate, with the deployment circuit breaker for rollback.

## Consequences

**Good.** The EKS control plane alone is ~$73/month before a single node,
roughly three times the total cost of this stack. ECS runs the same containers
with the same rollout semantics and gives automatic rollback as a platform
feature rather than as a controller to install and configure.

**Bad.** This project does not demonstrate Kubernetes. That is a real gap
against a job description that asks for it.

The defensible version of the answer is that EKS demonstrates Kubernetes, not
deployment engineering — and that knowing what something costs before building
it is itself the signal. `docs/` carries the migration path and its price
rather than the migration.
