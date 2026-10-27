# 0007 — Construct ARNs rather than reference them

- **Status:** Accepted
- **Date:** 2026-08-25

## Context

The IAM module needs ECS **service ARNs** to scope `ecs:UpdateService`. The
ECS module needs IAM **role ARNs** to build its task definition. Terraform
cannot resolve that cycle.

The usual workarounds are a two-stage apply, or widening the IAM policy to
`*` and calling it good enough.

## Decision

Construct the ARNs from the deterministic names this project already controls,
in a root-module `locals`, rather than reading them off the resource.

## Consequences

**Good.** One apply, and the deploy policy stays scoped to exactly two service
ARNs. This is a general technique: when two modules need each other's
identifiers and those identifiers are deterministic, derive rather than
reference.

**Bad.** The constructed ARN is not checked against reality. If the naming
convention in one module changes and the `locals` block does not, the policy
silently scopes to an ARN that does not exist and every deploy fails with
AccessDenied — a failure that does not point at its cause. The mitigation is
that both names derive from the same `local.name_prefix`.
