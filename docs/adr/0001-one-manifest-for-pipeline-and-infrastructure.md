# 0001 — One manifest read by both the pipeline and the infrastructure

- **Status:** Accepted
- **Date:** 2026-08-22

## Context

AutoDeployX deploys more than one service. Both the GitHub Actions build
matrix and the Terraform that creates ECS services, ECR repositories, target
groups and listeners need to know which services exist and what each one is
called.

The obvious implementation is a matrix in the workflow file and a list in
`main.tf`. Two lists, kept in step by hand.

The failure mode is not hypothetical. It is an image pushed to a repository
that has no ECS service to receive it, or an ECS service pointing at a
repository nothing pushes to — both discovered mid-deploy, which is the worst
moment to discover a naming mismatch.

## Decision

`services/services.json` is the only place a service is declared. GitHub
Actions builds its matrix from it with `jq | fromJSON`; Terraform reads the
same file with `jsondecode(file(...))` and `for_each`es over the result.

Adding a service is one JSON object. No workflow edit, no new Terraform
resource block.

## Consequences

**Good.** The two halves cannot disagree, because there is nothing to
disagree about. This is also the test of whether the thing is a pipeline or a
script that happens to run twice — and it is checkable: adding a third service
touches exactly one file.

**Bad.** The manifest is now a schema with no schema language. A typo in it
fails at `terraform apply` or mid-rollout rather than at edit time. That is
mitigated by `scripts/validate-manifest.sh`, which is itself negative-tested
against twelve broken variants — see ADR 0013 for the same pattern applied to
infrastructure policy.
