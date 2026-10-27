# One Application Load Balancer fronting every service.

locals {
  tls_enabled = var.domain_name != "" && var.route53_zone_id != ""

  # <service key>.<domain>. One certificate covers all of them: the first is
  # the subject, the rest are SANs, which is why a stable ordering matters.
  service_fqdns = {
    for key in keys(var.services) : key => "${key}.${var.domain_name}"
  }

  primary_service_key = length(var.services) > 0 ? sort(keys(var.services))[0] : ""
}

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [var.security_group_id]
  subnets            = var.subnet_ids

  # 30s: longer than any request these APIs make, short enough that a hung
  # upstream frees the connection instead of accumulating.
  idle_timeout = 30

  # False so `terraform destroy` works unattended. Production: true.
  enable_deletion_protection = false

  # Drops requests with header names ALB and the backend would parse
  # differently — the request-smuggling class of bug. Free, and off by default.
  drop_invalid_header_fields = true

  dynamic "access_logs" {
    for_each = var.enable_access_logs ? [1] : []
    content {
      bucket  = aws_s3_bucket.access_logs[0].id
      prefix  = var.name_prefix
      enabled = true
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb" })
}

resource "aws_lb_target_group" "this" {
  for_each = var.services

  # ALB target group names are capped at 32 characters and
  # "autodeployx-production-strategysphere" is 37.
  name        = "${substr("${var.name_prefix}-${each.key}", 0, 24)}-${substr(md5("${var.name_prefix}-${each.key}"), 0, 6)}"
  port        = var.target_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip" # required for awsvpc / Fargate — targets are ENIs, not instances

  health_check {
    enabled = true
    # /api/health, not /.
    path                = each.value.health_path
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2 # 2 × 15s = healthy ~30s after the app answers
    unhealthy_threshold = 3 # 3 × 15s = removed ~45s after it stops
  }

  # 30s instead of the 300s default.
  deregistration_delay = 30

  # Sticky sessions deliberately off. Both APIs are stateless; enabling
  # stickiness would mask a session-affinity bug rather than reveal it.
  stickiness {
    enabled = false
    type    = "lb_cookie"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-${each.key}", Service = each.key })

  # No create_before_destroy here, deliberately.
}

# Plain-HTTP mode: one listener per service, routed by port. Created only
# when there is no domain; with a certificate, host-based routing replaces it.
resource "aws_lb_listener" "this" {
  for_each = local.tls_enabled ? {} : var.services

  load_balancer_arn = aws_lb.this.arn
  port              = each.value.listener_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }

  tags = merge(var.tags, { Service = each.key })
}

# TLS.

resource "aws_acm_certificate" "this" {
  count = local.tls_enabled ? 1 : 0

  domain_name       = local.service_fqdns[local.primary_service_key]
  validation_method = "DNS"

  subject_alternative_names = [
    for key in sort(keys(var.services)) : local.service_fqdns[key]
    if key != local.primary_service_key
  ]

  # The certificate is referenced by the listener, so it cannot be destroyed while
  # the listener stands.
  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.tls_enabled ? {
    for opt in aws_acm_certificate.this[0].domain_validation_options :
    opt.domain_name => {
      name  = opt.resource_record_name
      type  = opt.resource_record_type
      value = opt.resource_record_value
    }
  } : {}

  zone_id = var.route53_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.value]
  ttl     = 60

  # ACM reuses one validation record across SANs on the same apex, so an
  # apply that writes the same name twice would otherwise fail on a conflict.
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count = local.tls_enabled ? 1 : 0

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# :443 — the real listener.
resource "aws_lb_listener" "https" {
  count = local.tls_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.tls_policy
  certificate_arn   = aws_acm_certificate_validation.this[0].certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "No service is published at this hostname.\n"
      status_code  = "404"
    }
  }

  tags = var.tags
}

resource "aws_lb_listener_rule" "https_host" {
  for_each = local.tls_enabled ? var.services : {}

  listener_arn = aws_lb_listener.https[0].arn
  # Deterministic and spread out, so inserting a service later does not
  # renumber the existing rules and churn the plan.
  priority = 100 + index(sort(keys(var.services)), each.key)

  condition {
    host_header {
      values = [local.service_fqdns[each.key]]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }

  tags = merge(var.tags, { Service = each.key })
}

# :80 exists only to redirect. 301, not 302: this is a permanent property of
# the deployment, and a 302 means every client re-asks forever.
resource "aws_lb_listener" "http_redirect" {
  count = local.tls_enabled ? 1 : 0

  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  tags = var.tags
}

resource "aws_route53_record" "service" {
  for_each = local.tls_enabled ? var.services : {}

  zone_id = var.route53_zone_id
  name    = local.service_fqdns[each.key]
  type    = "A"

  # An ALIAS, not a CNAME.
  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

# WAF. Off by default — see var.enable_waf for what it costs and why.

resource "aws_wafv2_web_acl" "this" {
  count = var.enable_waf ? 1 : 0

  name        = "${var.name_prefix}-waf"
  description = "Managed rule sets plus a per-IP rate limit, in front of the ALB."
  scope       = "REGIONAL" # CLOUDFRONT is the other value and needs us-east-1

  default_action {
    allow {}
  }

  # Rate limiting first, at priority 0. It is the rule most likely to actually
  # fire on this workload, and it is the one a managed rule group cannot do.
  rule {
    name     = "rate-limit"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-common"
    priority = 1

    # `none {}` lets the managed group's own actions apply. `count {}` would
    # make it logging-only while looking like protection.
    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"

        # SizeRestrictions_BODY blocks bodies over 8KB.
        rule_action_override {
          name = "SizeRestrictions_BODY"
          action_to_use {
            count {}
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-aws-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-waf"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

# A WAF with no logging tells you it blocked something and never what.
resource "aws_cloudwatch_log_group" "waf" {
  count = var.enable_waf ? 1 : 0

  name              = "aws-waf-logs-${var.name_prefix}"
  retention_in_days = var.waf_log_retention_days
  tags              = var.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  count = var.enable_waf ? 1 : 0

  resource_arn            = aws_wafv2_web_acl.this[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  # Authorization and Cookie are the two headers most likely to carry something
  # you do not want sitting in a log group for a week.
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }

  redacted_fields {
    single_header {
      name = "cookie"
    }
  }
}

resource "aws_wafv2_web_acl_association" "this" {
  count = var.enable_waf ? 1 : 0

  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this[0].arn
}

# ALB access logs. Off by default — nginx's JSON log already covers most of it.

data "aws_elb_service_account" "current" {
  count = var.enable_access_logs ? 1 : 0
}

resource "aws_s3_bucket" "access_logs" {
  count = var.enable_access_logs ? 1 : 0

  bucket        = "${var.name_prefix}-alb-logs-${substr(md5(var.name_prefix), 0, 8)}"
  force_destroy = true # so teardown works; these are logs, not records

  tags = var.tags
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  count = var.enable_access_logs ? 1 : 0

  bucket                  = aws_s3_bucket.access_logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  count = var.enable_access_logs ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    apply_server_side_encryption_by_default {
      # AES256, not KMS.
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  count = var.enable_access_logs ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = var.access_log_retention_days
    }
  }
}

data "aws_iam_policy_document" "access_logs" {
  count = var.enable_access_logs ? 1 : 0

  # The log delivery principal differs by region age: older regions use a
  # per-region account id, newer ones the logdelivery service principal.
  statement {
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.current[0].arn]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.access_logs[0].arn}/*"]
  }

  statement {
    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.access_logs[0].arn}/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  count = var.enable_access_logs ? 1 : 0

  bucket = aws_s3_bucket.access_logs[0].id
  policy = data.aws_iam_policy_document.access_logs[0].json
}
