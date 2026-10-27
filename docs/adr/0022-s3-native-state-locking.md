# 0022 — S3-native state locking, no DynamoDB

- **Status:** Accepted
- **Date:** 2026-10-21
- **Source:** Read off peer repositories in this domain; see ADR 0018 for how they were chosen.

## Context

The backend used an S3 bucket plus a DynamoDB table for locking, which was the only correct answer when the project was written. Terraform 1.10 added native S3 locking — a `.tflock` object taken with a conditional put, which S3 makes atomic — and 1.11 made it stable.

## Decision

`use_lockfile = true`, and the DynamoDB table deleted from the bootstrap stack. `required_version` raised to `>= 1.11.0` across the root, the bootstrap stack and all nine modules.

## Consequences

**Good.** One fewer resource to create, to forget on teardown, and to grant in every IAM policy. The `TF_LOCK_TABLE` repository variable is gone. The concurrency guarantee is unchanged: two applies still cannot both proceed.

**Bad.** It raises the floor to Terraform 1.11 everywhere, including anyone cloning this. An older Terraform does not error on `use_lockfile` — it ignores the setting, and the first concurrent apply corrupts state. The `required_version` constraint is what prevents that, which makes it load-bearing rather than documentation.

**Migration note.** An existing deployment's DynamoDB table is not removed by this change; it carries `prevent_destroy` and must be deleted by hand after confirming no state is locked in it.
