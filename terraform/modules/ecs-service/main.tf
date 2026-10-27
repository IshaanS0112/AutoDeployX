# One ECS service = one task definition with two containers (nginx + uvicorn)
# sharing an awsvpc network namespace, fronted by one ALB target group.

locals {
  log_group_name = "/ecs/${var.name_prefix}/${var.service_key}"

  # Secrets are referenced by ARN.
  api_secrets = concat(
    [{ name = "DATABASE_URL", valueFrom = var.database_url_secret_arn }],
    var.anthropic_secret_arn == "" ? [] : [
      { name = "ANTHROPIC_API_KEY", valueFrom = var.anthropic_secret_arn }
    ],
  )

  # --- Connection pool ----------------------------------------------------
  # db.t3.micro allows ~87 connections.
  db_environment = [
    { name = "DB_POOL_SIZE", value = tostring(var.db_pool_size) },
    { name = "DB_MAX_OVERFLOW", value = tostring(var.db_max_overflow) },
    { name = "DB_POOL_RECYCLE", value = tostring(var.db_pool_recycle_seconds) },
    { name = "DB_POOL_TIMEOUT", value = tostring(var.db_pool_timeout_seconds) },
    # Fail fast rather than hanging a worker on an unreachable database.
    { name = "DB_CONNECT_TIMEOUT", value = "5" },
  ]

  api_environment = concat(
    [
      { name = "GIT_SHA", value = var.image_tag },
      { name = "SERVICE_NAME", value = var.service_key },
      # Same-origin, so CORS is never in the request path. Set only so a
      # misconfiguration surfaces as a CORS error rather than a silent success.
      { name = "CORS_ORIGINS", value = var.public_url },
    ],
    local.db_environment,
    [for k, v in var.extra_environment : { name = k, value = v }],
  )
}

resource "aws_cloudwatch_log_group" "this" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  tags              = merge(var.tags, { Service = var.service_key })
}

resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name_prefix}-${var.service_key}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory

  execution_role_arn = var.execution_role_arn # ECS agent: pull, log, resolve secrets
  task_role_arn      = var.task_role_arn      # the app's own identity

  # ARM64, not X86_64. Graviton Fargate is about 20% cheaper for identical
  # work, and both images are pure Python and Node with no native x86 wheels.
  # The pipeline builds linux/arm64 to match — a mismatch here surfaces as
  # "exec format error" in the task log, with the deploy otherwise looking fine.
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = "${var.api_image_repository}:${var.image_tag}"
      essential = true

      # No portMappings. Nothing outside the task should reach uvicorn; nginx
      # gets there on loopback because they share a namespace.

      environment = local.api_environment
      secrets     = local.api_secrets

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = local.log_group_name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "api"
        }
      }

      # The container-level health check, distinct from the ALB's.
      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health/live', timeout=4).status==200 else 1)\" || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30 # create_all + benchmark load on first boot
      }

      # Prevents a runaway container from starving nginx of the task's memory.
      memoryReservation = floor(var.task_memory * 0.6)

      # --- Graceful shutdown, and why these three numbers are related ----- On a
      # rollout ECS sends SIGTERM, waits stopTimeout, then SIGKILL.
      stopTimeout = 30
    },
    {
      name      = "web"
      image     = "${var.web_image_repository}:${var.image_tag}"
      essential = true

      portMappings = [{
        containerPort = 80
        protocol      = "tcp"
      }]

      # nginx must not start proxying before uvicorn can answer, or the ALB sees
      # 502s from the new task and the circuit breaker trips on a healthy deploy.
      dependsOn = [{
        containerName = "api"
        condition     = "HEALTHY"
      }]

      environment = [
        { name = "GIT_SHA", value = var.image_tag },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = local.log_group_name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "web"
        }
      }

      # nginx drains after the API does, so it can keep answering until the last
      # proxied request completes.
      stopTimeout = 25
    },
  ])

  tags = merge(var.tags, { Service = var.service_key })
}

resource "aws_ecs_service" "this" {
  name            = "${var.name_prefix}-${var.service_key}"
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count

  # --- Zero-downtime rollout -------------------------------------------
  # min 100 / max 200 means: start the new task, health-check it, shift
  # traffic, then stop the old one. The old version serves throughout.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  # --- Automatic rollback ---------------------------------------------- THIS is
  # the feature.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  capacity_provider_strategy {
    capacity_provider = var.use_fargate_spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets         = var.subnet_ids
    security_groups = [var.security_group_id]
    # Required in a PUBLIC subnet to reach ECR. Must be false in a private
    # one, where a public IP is an address nothing can route to.
    assign_public_ip = var.assign_public_ip
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "web"
    container_port   = 80
  }

  # The ALB needs a moment after the task is running before its health checks can
  # pass.
  health_check_grace_period_seconds = 90

  # Interactive shell into a running task for debugging. See docs/runbook.md.
  enable_execute_command = true

  propagate_tags = "SERVICE"
  tags           = merge(var.tags, { Service = var.service_key })

  lifecycle {
    ignore_changes = [
      # The PIPELINE owns which image is deployed, via `aws ecs update-service` with
      # a new task definition revision.
      task_definition,
      desired_count,
    ]
  }

  depends_on = [aws_cloudwatch_log_group.this]
}

# Target-tracking autoscaling. Off by default.
#
# desired_count = 1 was a listed weakness: a Spot reclaim is an outage and
# there is no headroom for a traffic spike. This closes it without changing
# the default bill, because min_capacity stays at desired_count.
#
# Target tracking, not step scaling: you state the CPU you want to sit at and
# AWS works out the steps. Step scaling means picking thresholds and cooldowns
# by hand, which is a lot of configuration to get wrong for the same outcome.
#
# IMPORTANT: scaling up multiplies database connections. The manifest's
# connection budget is computed against desired_count, so raising max_capacity
# without re-checking it is how a service scales itself into
# "FATAL: remaining connection slots are reserved".
resource "aws_appautoscaling_target" "this" {
  count = var.enable_autoscaling ? 1 : 0

  service_namespace  = "ecs"
  resource_id        = "service/${split("/", var.cluster_arn)[1]}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"

  min_capacity = var.desired_count
  max_capacity = var.autoscaling_max_capacity
}

resource "aws_appautoscaling_policy" "cpu" {
  count = var.enable_autoscaling ? 1 : 0

  name               = "${var.name_prefix}-${var.service_key}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value = var.autoscaling_cpu_target

    # Scale out fast, scale in slowly. Scaling in too eagerly during a dip
    # means scaling out again a minute later, and every scale-out pays the
    # task's cold start twice.
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
  }
}
