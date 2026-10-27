# Policy fixtures

Deliberately broken Terraform. Each file violates exactly one rule in
`policy/autodeployx.rego`, and `scripts/policy-check.sh --self-test` asserts
that the rule actually rejects it.

A policy that has never failed is a policy nobody has verified. These are
never applied and never referenced by the real stack — they exist only to be
rejected.
