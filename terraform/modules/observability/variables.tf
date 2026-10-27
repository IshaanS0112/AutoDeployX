variable "name_prefix" { type = string }
variable "aws_region" { type = string }
variable "alert_email" { type = string }
variable "alb_arn_suffix" { type = string }
variable "alb_dns_name" { type = string }
variable "cluster_name" { type = string }
variable "rds_identifier" { type = string }

variable "services" {
  description = "service key -> { target_group_arn_suffix, service_name }"
  type = map(object({
    target_group_arn_suffix = string
    service_name            = string
  }))
}

variable "latency_p95_threshold_seconds" {
  description = "2s. Both APIs do synchronous computation and an optional LLM call; below this is comfortable, above it is worth looking at."
  type        = number
  default     = 2
}

variable "tags" {
  type    = map(string)
  default = {}
}

# --- SLO -------------------------------------------------------------------

variable "availability_slo" {
  description = <<-EOT
    Target availability as a fraction, e.g. 0.99 for "99% of requests succeed".

    99% is deliberately modest. It is one task on Fargate Spot behind one ALB
    with no multi-AZ database; claiming 99.9% would be a number this
    architecture cannot support, and an SLO you cannot meet is worse than none
    because it trains you to ignore the alert.
  EOT
  type        = number
  default     = 0.99

  validation {
    condition     = var.availability_slo > 0.5 && var.availability_slo < 1
    error_message = "availability_slo must be a fraction between 0.5 and 1, e.g. 0.99."
  }
}

variable "slo_burn_rate_fast" {
  description = "Fast-burn multiple of the error budget. 14.4x over 1 hour consumes 2% of a 30-day budget — the standard page-now threshold."
  type        = number
  default     = 14.4
}

variable "slo_burn_rate_slow" {
  description = "Slow-burn multiple. 6x over 6 hours consumes 5% of the budget — worth a ticket, not a page."
  type        = number
  default     = 6
}

variable "enable_slo_alarms" {
  description = "Burn-rate alarms are computed with metric math over ALB metrics that AWS already publishes, so they cost nothing. On by default."
  type        = bool
  default     = true
}
