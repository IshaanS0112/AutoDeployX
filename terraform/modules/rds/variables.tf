variable "name_prefix" { type = string }
variable "subnet_ids" { type = list(string) }
variable "security_group_id" { type = string }

variable "service_databases" {
  description = "service key -> { database, user }. One Postgres database and role per deployed service."
  type = map(object({
    database = string
    user     = string
  }))
}

variable "engine_version" {
  type    = string
  default = "16.4"
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "master_username" {
  type    = string
  default = "adxadmin"
}

variable "publicly_accessible" {
  type    = bool
  default = true
}

variable "backup_retention_days" {
  type    = number
  default = 1
}

variable "deletion_protection" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "multi_az" {
  description = <<-EOT
    Synchronous standby in a second AZ, with automatic failover.

    **Roughly 2x the RDS line** — on db.t3.micro that is about +$12/month
    inside the free tier's single-instance allowance, and the free tier does
    NOT cover the standby. Buys failover this project makes no SLA about.
  EOT
  type        = bool
  default     = false
}

variable "performance_insights_enabled" {
  description = <<-EOT
    Per-query wait-state analysis.

    Free at 7-day retention on most instance classes; **~$2-5/month** beyond
    that or with the longer retention tiers. Off by default because this
    workload's slow-query log is empty — there is no query detail to look at.
  EOT
  type        = bool
  default     = false
}

variable "monitoring_interval" {
  description = <<-EOT
    Enhanced monitoring granularity in seconds: 0 (off), 1, 5, 10, 15, 30 or 60.

    **Billed per instance per minute of metrics delivered** — roughly $2-5/month
    at a 60s interval, more as the interval shortens. It reports OS-level
    metrics (per-process CPU, disk queue depth) that the free CloudWatch RDS
    metrics do not.
  EOT
  type        = number
  default     = 0

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "monitoring_interval must be one of 0, 1, 5, 10, 15, 30, 60."
  }
}
