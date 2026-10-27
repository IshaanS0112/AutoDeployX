# AutoDeployX — root module.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name_prefix = "${var.project}-${var.environment}"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Repo        = "${var.github_owner}/${var.github_repo}"
  }

  manifest = jsondecode(file("${path.module}/../services/services.json"))
  services = { for s in local.manifest.services : s.key => s }

  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # One ECR repository per container image.
  ecr_repository_names = merge([
    for key, svc in local.services : {
      "${var.project}/${key}-api" = {}
      "${var.project}/${key}-web" = {}
    }
  ]...)

  cluster_name = local.name_prefix
  cluster_arn  = "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:cluster/${local.cluster_name}"

  # Constructed rather than read from the resource, deliberately.
  ecs_service_arns = [
    for key in keys(local.services) :
    "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:service/${local.cluster_name}/${local.name_prefix}-${key}"
  ]

  alert_email = var.alert_email != "" ? var.alert_email : var.budget_notification_email

  # Both are needed: a domain with no zone to validate in cannot get a
  # certificate, and a zone with no domain has nothing to publish.
  tls_enabled = var.domain_name != "" && var.route53_zone_id != ""

  # With TLS the ALB needs exactly two public ports — :443 for traffic and :80
  # for the redirect. Without it, one port per service.
  alb_public_ports = local.tls_enabled ? [80, 443] : [for s in local.services : s.alb_listener_port]
}

# Cost guardrails first. Nothing below this line is free.
module "budgets" {
  source = "./modules/budgets"

  name_prefix        = local.name_prefix
  thresholds_usd     = var.budget_thresholds_usd
  notification_email = var.budget_notification_email

  enable_cost_anomaly_detection = var.enable_cost_anomaly_detection
}

module "networking" {
  source = "./modules/networking"

  name_prefix        = local.name_prefix
  availability_zones = var.availability_zones
  alb_listener_ports = local.alb_public_ports
  task_ingress_port  = 80
  operator_cidr      = var.operator_cidr

  # All off by default. Each one moves the monthly bill; see
  # docs/cost-breakdown.md and `make cost`.
  enable_private_subnets = var.enable_private_subnets
  enable_nat_gateway     = var.enable_nat_gateway
  nat_mode               = var.nat_mode
  single_nat_gateway     = var.single_nat_gateway
  enable_vpc_endpoints   = var.enable_vpc_endpoints
  enable_flow_logs       = var.enable_flow_logs

  tags = local.common_tags
}

module "ecr" {
  source = "./modules/ecr"

  repositories = local.ecr_repository_names
  tags         = local.common_tags
}

module "rds" {
  source = "./modules/rds"

  name_prefix = local.name_prefix
  # Private subnets when they exist, public otherwise. The networking module
  # decides; nothing here has to know which topology is in force.
  subnet_ids        = module.networking.workload_subnet_ids
  security_group_id = module.networking.rds_security_group_id

  service_databases = {
    for key, svc in local.services : key => {
      database = svc.db_name
      user     = svc.db_user
    }
  }

  instance_class        = var.rds_instance_class
  allocated_storage     = var.rds_allocated_storage
  backup_retention_days = var.rds_backup_retention_days
  deletion_protection   = var.rds_deletion_protection

  # A database in a private subnet has no public endpoint to expose.
  publicly_accessible          = !module.networking.private_networking_enabled
  multi_az                     = var.rds_multi_az
  performance_insights_enabled = var.rds_performance_insights
  monitoring_interval          = var.rds_enhanced_monitoring_interval

  tags = local.common_tags
}

# The Anthropic key, if supplied.
resource "aws_secretsmanager_secret" "anthropic" {
  count = var.anthropic_api_key != "" ? 1 : 0

  name                    = "${local.name_prefix}/anthropic/api-key"
  description             = "Anthropic API key, injected into the api container at runtime."
  recovery_window_in_days = 0

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "anthropic" {
  count = var.anthropic_api_key != "" ? 1 : 0

  secret_id     = aws_secretsmanager_secret.anthropic[0].id
  secret_string = var.anthropic_api_key
}

module "alb" {
  source = "./modules/alb"

  name_prefix = local.name_prefix
  vpc_id      = module.networking.vpc_id
  # The ALB is ALWAYS in the public subnets, whatever the workload does.
  subnet_ids        = module.networking.public_subnet_ids
  security_group_id = module.networking.alb_security_group_id

  services = {
    for key, svc in local.services : key => {
      listener_port = svc.alb_listener_port
      health_path   = svc.health_path
    }
  }

  domain_name     = var.domain_name
  route53_zone_id = var.route53_zone_id

  enable_waf         = var.enable_waf
  enable_access_logs = var.enable_alb_access_logs

  tags = local.common_tags
}

module "iam" {
  source = "./modules/iam"

  name_prefix           = local.name_prefix
  allowed_subjects      = var.github_allowed_refs
  plan_allowed_subjects = var.github_plan_allowed_refs

  # Constructed, not referenced — same technique as the service ARNs (ADR 0007).
  plan_readable_iam_arns = [
    "arn:${local.partition}:iam::${local.account_id}:role/${local.name_prefix}-*",
    "arn:${local.partition}:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com",
  ]

  ecr_repository_arns = module.ecr.repository_arns
  ecs_service_arns    = local.ecs_service_arns
  ecs_cluster_arn     = local.cluster_arn

  # Constructed, not referenced — same technique and same reason as ecs_service_arns
  # above (ADR 0007).
  migration_task_definition_arns = [
    for key in keys(local.services) :
    "arn:${local.partition}:ecs:${var.aws_region}:${local.account_id}:task-definition/${local.name_prefix}-${key}-migrate:*"
  ]

  secret_arns = concat(
    module.rds.all_secret_arns,
    [for s in aws_secretsmanager_secret.anthropic : s.arn],
  )

  tags = local.common_tags
}

resource "aws_ecs_cluster" "this" {
  name = local.cluster_name

  setting {
    name = "containerInsights"
    # Off by default: Container Insights publishes custom metrics that are
    # not free-tier eligible and can cost more than the compute they observe.
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  tags = local.common_tags
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }
}

module "service" {
  source   = "./modules/ecs-service"
  for_each = local.services

  name_prefix = local.name_prefix
  service_key = each.key
  aws_region  = var.aws_region

  cluster_arn = aws_ecs_cluster.this.arn
  subnet_ids  = module.networking.workload_subnet_ids
  # A task in a public subnet needs a public IP to reach ECR at all.
  assign_public_ip  = module.networking.assign_public_ip
  security_group_id = module.networking.tasks_security_group_id
  target_group_arn  = module.alb.target_group_arns[each.key]

  execution_role_arn = module.iam.ecs_task_execution_role_arn
  task_role_arn      = module.iam.ecs_task_role_arn

  api_image_repository = module.ecr.repository_urls["${var.project}/${each.key}-api"]
  web_image_repository = module.ecr.repository_urls["${var.project}/${each.key}-web"]

  database_url_secret_arn = module.rds.database_url_secret_arns[each.key]
  anthropic_secret_arn    = length(aws_secretsmanager_secret.anthropic) > 0 ? aws_secretsmanager_secret.anthropic[0].arn : ""

  public_url        = module.alb.service_urls[each.key]
  extra_environment = each.value.env

  cpu_architecture         = var.cpu_architecture
  enable_autoscaling       = var.enable_autoscaling
  autoscaling_max_capacity = var.autoscaling_max_capacity
  db_pool_size             = each.value.db.pool_size
  db_max_overflow          = each.value.db.max_overflow
  db_pool_recycle_seconds  = each.value.db.pool_recycle_seconds
  db_pool_timeout_seconds  = each.value.db.pool_timeout_seconds

  task_cpu           = each.value.task_cpu
  task_memory        = each.value.task_memory
  desired_count      = each.value.desired_count
  use_fargate_spot   = var.use_fargate_spot
  log_retention_days = var.log_retention_days

  tags = local.common_tags

  depends_on = [aws_ecs_cluster_capacity_providers.this]
}

# Migration task definitions, one per service that has them enabled.
module "migrations" {
  source   = "./modules/migrations"
  for_each = local.services

  name_prefix = local.name_prefix
  service_key = each.key
  aws_region  = var.aws_region

  execution_role_arn = module.iam.ecs_task_execution_role_arn
  task_role_arn      = module.iam.ecs_task_role_arn

  api_image_repository    = module.ecr.repository_urls["${var.project}/${each.key}-api"]
  database_url_secret_arn = module.rds.database_url_secret_arns[each.key]
  migration_command       = each.value.migrations.command
  cpu_architecture        = var.cpu_architecture

  log_retention_days = var.log_retention_days
  tags               = local.common_tags
}

module "observability" {
  source = "./modules/observability"

  name_prefix    = local.name_prefix
  aws_region     = var.aws_region
  alert_email    = local.alert_email
  alb_arn_suffix = module.alb.arn_suffix
  alb_dns_name   = module.alb.dns_name
  cluster_name   = aws_ecs_cluster.this.name
  rds_identifier = module.rds.identifier

  services = {
    for key in keys(local.services) : key => {
      target_group_arn_suffix = module.alb.target_group_arn_suffixes[key]
      service_name            = module.service[key].service_name
    }
  }

  availability_slo  = var.availability_slo
  enable_slo_alarms = var.enable_slo_alarms

  tags = local.common_tags
}
