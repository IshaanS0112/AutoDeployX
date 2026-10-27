# Must be rejected by: a billable switch must name its price
variable "enable_waf" {
  description = "Turn on WAF. Recommended for production."
  type        = bool
  default     = false
}
