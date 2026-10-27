# Budget alarms.

resource "aws_budgets_budget" "monthly" {
  for_each = { for t in var.thresholds_usd : tostring(t) => t }

  name         = "${var.name_prefix}-monthly-${each.key}usd"
  budget_type  = "COST"
  limit_amount = tostring(each.value)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # ACTUAL: fire when spend has really crossed the line.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.notification_email]
  }

  # FORECASTED: fire when AWS projects the month will cross the line, which is
  # days of warning rather than a notification after the fact.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.notification_email]
  }
}

# A zero-spend alarm is a different signal: it fires when something that
# SHOULD be free starts charging, usually an expired free-tier allowance.
resource "aws_budgets_budget" "free_tier_breach" {
  count = var.enable_free_tier_alarm ? 1 : 0

  name         = "${var.name_prefix}-free-tier-breach"
  budget_type  = "COST"
  limit_amount = "1"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.notification_email]
  }
}

# Cost Anomaly Detection.

resource "aws_ce_anomaly_monitor" "this" {
  count = var.enable_cost_anomaly_detection ? 1 : 0

  name = "${var.name_prefix}-anomaly-monitor"
  # DIMENSIONAL on SERVICE, not a tag-scoped monitor: tags only cover what
  # this project created, and the bill that hurts is usually something else.
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "this" {
  count = var.enable_cost_anomaly_detection ? 1 : 0

  name      = "${var.name_prefix}-anomaly-alerts"
  frequency = "DAILY"

  monitor_arn_list = [aws_ce_anomaly_monitor.this[0].arn]

  subscriber {
    type    = "EMAIL"
    address = var.notification_email
  }

  # Without a threshold every rounding blip is an anomaly and the mail goes to a
  # filter.
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = [tostring(var.anomaly_threshold_usd)]
    }
  }
}
