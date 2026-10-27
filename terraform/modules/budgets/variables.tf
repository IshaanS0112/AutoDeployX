variable "name_prefix" { type = string }

variable "thresholds_usd" {
  type    = list(number)
  default = [5, 10, 20]
}

variable "notification_email" { type = string }

variable "enable_free_tier_alarm" {
  description = "Alert on the first dollar of spend at all — catches a free-tier allowance quietly running out."
  type        = bool
  default     = true
}

variable "enable_cost_anomaly_detection" {
  description = <<-EOT
    AWS Cost Anomaly Detection. Free — it is machine learning over the billing
    data AWS already has, and it is not charged for.

    It answers a question the fixed budgets cannot. A budget fires when spend
    crosses a line; this fires when spend changes SHAPE. A NAT gateway created
    by accident on the 2nd of the month costs $2 by the 3rd and trips no
    budget at all, but it is a clear anomaly against a stack whose baseline is
    pennies a day.
  EOT
  type        = bool
  default     = true
}

variable "anomaly_threshold_usd" {
  description = "Minimum absolute anomaly worth an email. $1 on a stack that idles at $0 is signal; lower than that is noise from rounding."
  type        = number
  default     = 1
}
