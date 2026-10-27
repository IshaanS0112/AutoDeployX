# Must be rejected by: enhanced monitoring defaults to 0
variable "rds_enhanced_monitoring_interval" {
  description = "OS metrics interval. Billed per instance per minute, ~$2-5/month."
  type        = number
  default     = 60
}
