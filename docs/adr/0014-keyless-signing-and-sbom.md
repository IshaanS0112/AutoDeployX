# 0014 — Keyless image signing and SBOM attestation

- **Status:** Accepted
- **Date:** 2026-09-20

## Context

Trivy gates the build on HIGH and CRITICAL CVEs, which answers 'is this image
vulnerable today'. It does not answer 'six months from now a CVE is announced
in a transitive dependency — which of my images contain it', and it does not
answer 'was this image built by the pipeline, or pushed by hand'.

Signing usually means a private key, which means a key to store, rotate and
leak.

## Decision

Keyless `cosign`. The build job exchanges its GitHub OIDC token for a
short-lived certificate from Fulcio, signs the image **digest**, and the
signature is recorded in the Rekor transparency log. An SPDX SBOM is generated
with `syft` and attached as an attestation.

The deploy job then **verifies** the signature and the certificate identity
before telling ECS to run anything.

## Consequences

**Good.** Same reasoning as OIDC-to-AWS, applied to artifacts instead of API
calls: no long-lived credential exists. The certificate identity is checked,
not just the signature — 'it has a valid signature' only means somebody signed
it, whereas 'the certificate says this repository, issued by GitHub's OIDC
provider' means this pipeline signed it. The digest is signed rather than the
tag, because a signature over a mutable pointer is not a signature over
anything.

**Bad.** Verification happens in the pipeline, not in the cluster. Nothing
stops someone with ECR write access and `ecs:UpdateService` from deploying an
unsigned image out of band — that needs an admission controller, which ECS does
not have. The honest statement is that this makes the pipeline's own artifacts
verifiable, not that the cluster refuses unsigned images.

**Also.** Rekor is public. The image digests, repository name and workflow
identity are published to a transparency log by design. That is the point, and
it is worth knowing before turning it on for something private.
