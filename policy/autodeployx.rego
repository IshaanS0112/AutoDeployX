# AutoDeployX's rules about itself.

package main

# --- Cost ------------------------------------------------------------------

# The NAT gateway claim, in its current form.
deny contains msg if {
	some name
	gw := input.resource.aws_nat_gateway[name][_]
	not is_gated(gw)
	msg := sprintf("aws_nat_gateway.%s: not gated behind count or for_each, so it is created unconditionally. That is ~$32/month per gateway nobody opted into.", [name])
}

deny contains msg if {
	some name
	ep := input.resource.aws_vpc_endpoint[name][_]
	ep.vpc_endpoint_type == "Interface"
	not is_gated(ep)
	msg := sprintf("aws_vpc_endpoint.%s: an ungated INTERFACE endpoint is ~$7.20/month per AZ. Gate it behind a variable.", [name])
}

deny contains msg if {
	some name
	inst := input.resource.aws_instance[name][_]
	not is_gated(inst)
	msg := sprintf("aws_instance.%s: an ungated EC2 instance bills by the hour whether or not anyone chose it. Gate it behind a variable.", [name])
}

deny contains msg if {
	some name
	acl := input.resource.aws_wafv2_web_acl[name][_]
	not is_gated(acl)
	msg := sprintf("aws_wafv2_web_acl.%s: an ungated web ACL is ~$5/month base plus per-rule and per-request charges — more than the rest of this stack.", [name])
}

is_gated(resource) if {
	resource.count
}

is_gated(resource) if {
	resource.for_each
}

# Every switch that costs money must default to OFF.
expensive_switches := {
	"enable_nat_gateway",
	"enable_vpc_endpoints",
	"enable_private_subnets",
	"enable_flow_logs",
	"enable_waf",
	"enable_alb_access_logs",
	"rds_multi_az",
	"rds_performance_insights",
	"enable_container_insights",
}

deny contains msg if {
	some name
	expensive_switches[name]
	v := input.variable[name][_]
	v.default != false
	msg := sprintf("variable %s defaults to %v. Every switch that costs money defaults to OFF in this project — see docs/cost-breakdown.md.", [name, v.default])
}

deny contains msg if {
	v := input.variable.rds_enhanced_monitoring_interval[_]
	v.default != 0
	msg := sprintf("variable rds_enhanced_monitoring_interval defaults to %v. Enhanced monitoring is billed per instance per minute; it defaults to 0.", [v.default])
}

# A variable that costs money must SAY what it costs.
deny contains msg if {
	some name
	expensive_switches[name]
	v := input.variable[name][_]
	not mentions_cost(v.description)
	msg := sprintf("variable %s is a billable switch but its description names no price. State what turning it on costs.", [name])
}

mentions_cost(description) if {
	contains(description, "$")
}

# Log groups that never expire are how a log bill grows without anyone
# deciding to spend the money.
deny contains msg if {
	some name
	group := input.resource.aws_cloudwatch_log_group[name][_]
	not group.retention_in_days
	msg := sprintf("aws_cloudwatch_log_group.%s: no retention_in_days, so logs are kept forever and billed forever.", [name])
}

# The root module must create budget alarms. Identified by the presence of the
# networking module, which only the root has.
deny contains msg if {
	input.module.networking
	not input.module.budgets
	msg := "the root module declares networking but not budgets: cost guardrails are applied FIRST in this project, before anything billable exists."
}

# --- Network isolation -----------------------------------------------------

# The database is in a public subnet as a deliberate cost decision.
deny contains msg if {
	some name
	rule := input.resource.aws_vpc_security_group_ingress_rule[name][_]
	rule.from_port == 5432
	rule.cidr_ipv4 == "0.0.0.0/0"
	msg := sprintf("aws_vpc_security_group_ingress_rule.%s: Postgres open to 0.0.0.0/0. The database sits in a public subnet precisely because the security group is the boundary.", [name])
}

deny contains msg if {
	some name
	rule := input.resource.aws_vpc_security_group_ingress_rule[name][_]
	rule.from_port == 22
	msg := sprintf("aws_vpc_security_group_ingress_rule.%s: SSH ingress. There is no host to SSH into — debugging goes through ECS Exec, which is IAM-controlled and audited.", [name])
}

# --- Deployment integrity --------------------------------------------------

# "Roll back to a3f9c21" has no defined meaning against a mutable tag.
deny contains msg if {
	some name
	repo := input.resource.aws_ecr_repository[name][_]
	repo.image_tag_mutability != "IMMUTABLE"
	msg := sprintf("aws_ecr_repository.%s: image_tag_mutability is not IMMUTABLE. With mutable tags a rollback to a specific SHA is not a defined operation.", [name])
}

# The headline feature of the project. If this is ever switched off, a bad
# deploy stops rolling itself back and nothing else in the pipeline notices.
deny contains msg if {
	some name
	svc := input.resource.aws_ecs_service[name][_]
	not svc.deployment_circuit_breaker
	msg := sprintf("aws_ecs_service.%s: no deployment_circuit_breaker. Automatic rollback is the headline claim of this project.", [name])
}

deny contains msg if {
	some name
	svc := input.resource.aws_ecs_service[name][_]
	cb := svc.deployment_circuit_breaker[_]
	cb.rollback != true
	msg := sprintf("aws_ecs_service.%s: circuit breaker has rollback = false, so a failed deploy is detected and then left failed.", [name])
}

# §4.6 — without this, every `terraform apply` after a deploy silently reverts
# the service to whatever image tag is in the tfvars.
deny contains msg if {
	some name
	svc := input.resource.aws_ecs_service[name][_]
	not ignores_task_definition(svc)
	msg := sprintf("aws_ecs_service.%s: lifecycle.ignore_changes must include task_definition, or terraform apply undoes the most recent deployment.", [name])
}

ignores_task_definition(svc) if {
	lc := svc.lifecycle[_]
	lc.ignore_changes[_] == "${task_definition}"
}

# A task definition pinned to :latest cannot answer "which commit is in
# production", and cannot be rolled back to a known-good artifact.
deny contains msg if {
	some kind, name
	resource := input.resource[kind][name][_]
	value := resource[_]
	is_string(value)
	contains(value, ":latest")
	msg := sprintf("%s.%s: refers to a :latest tag. Images are tagged with the git SHA so the running commit is always identifiable.", [kind, name])
}

# --- Secrets ---------------------------------------------------------------

# A secret in `environment` is a plaintext value in the task definition, which is
# readable by anyone with ecs:DescribeTaskDefinition.
deny contains msg if {
	some name
	td := input.resource.aws_ecs_task_definition[name][_]
	is_string(td.container_definitions)
	regex.match(`(?i)\{\s*name\s*=\s*"[^"]*(PASSWORD|SECRET|TOKEN|API_KEY|CREDENTIAL)[^"]*"\s*,\s*value\s*=`, td.container_definitions)
	msg := sprintf("aws_ecs_task_definition.%s: a secret-looking name appears in `environment` rather than `secrets`. Environment values are plaintext in the task definition.", [name])
}

# The default 30-day recovery window breaks rebuild-after-teardown: re-applying
# fails with "a secret with this name is scheduled for deletion".
deny contains msg if {
	some name
	secret := input.resource.aws_secretsmanager_secret[name][_]
	secret.recovery_window_in_days != 0
	msg := sprintf("aws_secretsmanager_secret.%s: recovery_window_in_days must be 0. This stack is destroyed and rebuilt routinely, and a scheduled-for-deletion secret blocks the rebuild for 30 days.", [name])
}

# --- Portability -----------------------------------------------------------

# A literal account id in the source means the stack only applies to one account,
# and usually means an ARN that should have been constructed from
deny contains msg if {
	some kind, name
	resource := input.resource[kind][name][_]
	value := resource[_]
	is_string(value)
	regex.match(`arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:`, value)
	msg := sprintf("%s.%s: hardcoded 12-digit account id in an ARN. Construct it from data.aws_caller_identity so the stack applies to any account.", [kind, name])
}

# --- Warnings (do not fail the build) --------------------------------------

warn contains msg if {
	some name
	svc := input.resource.aws_ecs_service[name][_]
	not svc.health_check_grace_period_seconds
	msg := sprintf("aws_ecs_service.%s: no health_check_grace_period_seconds. ECS will kill tasks as unhealthy while they are still legitimately starting, and the deploy fails in a loop that looks exactly like a broken build (trap 22).", [name])
}

warn contains msg if {
	some name
	lb := input.resource.aws_lb[name][_]
	not lb.drop_invalid_header_fields
	msg := sprintf("aws_lb.%s: drop_invalid_header_fields is off. It is free and it closes the request-smuggling class of bug.", [name])
}

# --- Backend invariants ----------------------------------------------------

# A migration task must not hold a connection pool.
deny contains msg if {
	some name
	td := input.resource.aws_ecs_task_definition[name][_]
	is_string(td.container_definitions)
	contains(td.container_definitions, "migrate")
	regex.match(`"DB_POOL_SIZE"\s*,?\s*value\s*=\s*"([2-9]|[1-9][0-9]+)"`, td.container_definitions)
	msg := sprintf("aws_ecs_task_definition.%s: the migration task sets DB_POOL_SIZE above 1. It runs during the 200%% rollout window and would reserve connections the live service needs.", [name])
}

# A container the ALB routes to must be able to outlive the load balancer's drain.
warn contains msg if {
	some name
	td := input.resource.aws_ecs_task_definition[name][_]
	is_string(td.container_definitions)
	contains(td.container_definitions, "\"name\": \"api\"")
	msg := sprintf("aws_ecs_task_definition.%s: check that the api container's stopTimeout still exceeds the ALB deregistration_delay (30s). See ADR 0017.", [name])
}

# The migration task definition must exist for every service, or turning
# migrations on in the manifest silently does nothing.
deny contains msg if {
	input.module.service
	not input.module.migrations
	msg := "the root module declares service task definitions but no migrations module: enabling migrations in services.json would then have nothing to run."
}
