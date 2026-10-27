# 0019 — ARM64 Fargate instead of X86_64

- **Status:** Accepted
- **Date:** 2026-10-21
- **Source:** Read off peer repositories in this domain; see ADR 0018 for how they were chosen.

## Context

Both task definitions pinned `cpu_architecture = "X86_64"`, which was the default rather than a decision. AWS Graviton is roughly 20% cheaper for the same Fargate work.

## Decision

`var.cpu_architecture`, defaulting to **ARM64**, on both the service and migration task definitions. The pipeline builds `linux/arm64` images, with `docker/setup-qemu-action` so the x86 runner can emulate the target.

## Consequences

**Good.** About 20% off the Fargate line for no behavioural change. Both images are pure Python and Node with no native x86 wheels, so nothing had to be ported.

**Bad.** The architecture is now stated in two places that must agree — the task definition and the build's `platforms`. A mismatch fails at task start with `exec format error`, which says nothing about architecture and looks like a broken image.

**Also.** Cross-architecture builds under QEMU are slower than native. The dependency layer still caches, so a source-only commit is unaffected, but a dependency change costs more build time than it did.
