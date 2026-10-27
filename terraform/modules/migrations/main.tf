# Schema migrations as a one-off ECS task, run BEFORE the service rollout.

locals {
  log_group_name = "/ecs/${var.name_prefix}/${var.service_key}-migrate"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  tags              = merge(var.tags, { Service = var.service_key, Role = "migrations" })
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name_prefix}-${var.service_key}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"

  # Deliberately small. A migration is IO-bound against the database; giving it
  # the service's CPU allocation just costs more for the 20 seconds it runs.
  cpu    = var.task_cpu
  memory = var.task_memory

  execution_role_arn = var.execution_role_arn
  task_role_arn      = var.task_role_arn

  # ARM64, matching the service. A migration running on a different
  # architecture than the service it migrates for is a difference with no
  # reason to exist.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = "migrate"
      image     = "${var.api_image_repository}:${var.image_tag}"
      essential = true
      command   = var.migration_command

      environment = [
        { name = "GIT_SHA", value = var.image_tag },
        { name = "SERVICE_NAME", value = var.service_key },
        # One connection, no pool.
        { name = "DB_POOL_SIZE", value = "1" },
        { name = "DB_MAX_OVERFLOW", value = "0" },
      ]

      secrets = [
        { name = "DATABASE_URL", valueFrom = var.database_url_secret_arn },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = local.log_group_name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "migrate"
        }
      }

      # No healthCheck. This container is expected to exit, and an ECS health
      # check on a container that exits by design reports it as unhealthy.
    },
  ])

  tags = merge(var.tags, { Service = var.service_key, Role = "migrations" })
}
