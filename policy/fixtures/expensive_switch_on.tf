# Must be rejected by: expensive switches default OFF
variable "enable_nat_gateway" {
  description = "A NAT gateway, ~$32/month."
  type        = bool
  default     = true
}
