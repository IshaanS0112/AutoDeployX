# One db.t3.micro Postgres instance hosting a database per service.

resource "aws_db_subnet_group" "this" {
  name        = "${var.name_prefix}-db"
  description = "Subnets for the ${var.name_prefix} database"
  subnet_ids  = var.subnet_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-db" })
}

# The master password is generated here and never printed, never committed, and
# never passed as an environment variable.
resource "random_password" "master" {
  length = 32
  # RDS rejects '/', '@', '"' and space in a master password.
  override_special = "!#$%&*()-_=+[]{}<>:?"
  special          = true
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name_prefix}-postgres"
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  # gp2 rather than gp3: the free tier covers 20GB of "General Purpose (SSD)"
  # and gp2 is what that allowance is written against for db.t3.micro.
  storage_type      = "gp2"
  storage_encrypted = true

  # A maintenance database.
  db_name  = "postgres"
  username = var.master_username
  password = random_password.master.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]

  # In a public subnet, reachable only from the task security group and one operator
  # CIDR.
  publicly_accessible = var.publicly_accessible

  # ~2x the RDS line, for failover this project makes no SLA about. See
  # var.multi_az for the number.
  multi_az                = var.multi_az
  backup_retention_period = var.backup_retention_days
  backup_window           = "18:30-19:00" # 00:00-00:30 IST — off-peak for the operator
  maintenance_window      = "Mon:19:30-Mon:20:30"

  auto_minor_version_upgrade = true
  apply_immediately          = true # no maintenance-window waiting on a demo stack

  deletion_protection = var.deletion_protection
  # Both true so `terraform destroy` completes without prompting for a snapshot name
  # and without leaving a billable snapshot behind.
  skip_final_snapshot = true

  # Performance Insights is NOT free on db.t3.micro beyond the 7-day retention tier,
  # and enhanced monitoring bills per-instance-per-minute.
  performance_insights_enabled          = var.performance_insights_enabled
  performance_insights_retention_period = var.performance_insights_enabled ? 7 : null
  monitoring_interval                   = var.monitoring_interval
  monitoring_role_arn                   = var.monitoring_interval > 0 ? aws_iam_role.enhanced_monitoring[0].arn : null

  # Postgres logs to CloudWatch so a connection failure is diagnosable without
  # SSH-ing anywhere.
  enabled_cloudwatch_logs_exports = ["postgresql"]

  tags = merge(var.tags, { Name = "${var.name_prefix}-postgres" })

  lifecycle {
    ignore_changes = [
      # RDS rewrites this after a minor version auto-upgrade; without this,
      # every subsequent plan would propose downgrading the engine.
      engine_version,
    ]
  }
}

# --- Secrets --------------------------------------------------------------- One
# secret per service holding that service's full DATABASE_URL, plus one

resource "aws_secretsmanager_secret" "master" {
  name        = "${var.name_prefix}/rds/master"
  description = "RDS master credentials. Used only by scripts/init-databases.sh."

  # 0 = delete immediately on destroy.
  recovery_window_in_days = 0

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "master" {
  secret_id = aws_secretsmanager_secret.master.id
  secret_string = jsonencode({
    username = var.master_username
    password = random_password.master.result
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    engine   = "postgres"
  })
}

# Per-service application role passwords.
resource "random_password" "app" {
  for_each = var.service_databases

  length           = 32
  override_special = "!#$%&*()-_=+[]{}<>:?"
  special          = true
}

resource "aws_secretsmanager_secret" "database_url" {
  for_each = var.service_databases

  name                    = "${var.name_prefix}/${each.key}/database-url"
  description             = "SQLAlchemy connection string for ${each.key}"
  recovery_window_in_days = 0

  tags = merge(var.tags, { Service = each.key })
}

resource "aws_secretsmanager_secret_version" "database_url" {
  for_each = var.service_databases

  secret_id = aws_secretsmanager_secret.database_url[each.key].id
  # Plain string, not JSON: the ECS agent injects the secret value verbatim,
  # so a JSON blob would arrive as a JSON blob in the environment variable.
  secret_string = format(
    "postgresql+psycopg2://%s:%s@%s:%s/%s",
    each.value.user,
    urlencode(random_password.app[each.key].result),
    aws_db_instance.this.address,
    aws_db_instance.this.port,
    each.value.database,
  )
}

# The bootstrap script reads these to create the roles with matching passwords.
resource "aws_secretsmanager_secret" "app_password" {
  for_each = var.service_databases

  name                    = "${var.name_prefix}/${each.key}/db-password"
  description             = "Password for the ${each.value.user} Postgres role"
  recovery_window_in_days = 0

  tags = merge(var.tags, { Service = each.key })
}

resource "aws_secretsmanager_secret_version" "app_password" {
  for_each = var.service_databases

  secret_id     = aws_secretsmanager_secret.app_password[each.key].id
  secret_string = random_password.app[each.key].result
}

# Enhanced monitoring needs a role RDS can assume to publish OS-level metrics.

data "aws_iam_policy_document" "enhanced_monitoring_assume" {
  count = var.monitoring_interval > 0 ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["monitoring.rds.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "enhanced_monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  name               = "${var.name_prefix}-rds-monitoring"
  assume_role_policy = data.aws_iam_policy_document.enhanced_monitoring_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "enhanced_monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.enhanced_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
