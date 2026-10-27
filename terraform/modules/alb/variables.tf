variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "subnet_ids" { type = list(string) }
variable "security_group_id" { type = string }

variable "services" {
  description = "service key -> { listener_port, health_path }"
  type = map(object({
    listener_port = number
    health_path   = string
  }))
}

variable "target_port" {
  description = "Container port registered in the target group (nginx)."
  type        = number
  default     = 80
}

variable "tags" {
  type    = map(string)
  default = {}
}

# --- TLS (optional) --------------------------------------------------------
# Everything below is inert unless `domain_name` is set.

variable "domain_name" {
  description = <<-EOT
    Apex domain you control, e.g. "example.com". Leave empty for plain HTTP on
    per-service ports.

    When set, each service is published at <service key>.<domain_name> behind
    one HTTPS listener, :80 becomes a permanent redirect to :443, and the
    per-service HTTP port listeners are not created — host-based routing makes
    them redundant and the :8080 oddity goes away with them.
  EOT
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone for domain_name. Required when domain_name is set — it is where the ACM validation record and the service ALIAS records are written."
  type        = string
  default     = ""

  validation {
    condition     = var.route53_zone_id == "" || can(regex("^Z[A-Z0-9]+$", var.route53_zone_id))
    error_message = "route53_zone_id must look like a Route 53 zone id (Z...)."
  }
}

variable "tls_policy" {
  description = "ALB SSL policy. The TLS13 policy drops everything below TLS 1.2."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

# --- Optional, and each one costs money ------------------------------------

variable "enable_waf" {
  description = <<-EOT
    AWS WAFv2 in front of the ALB, with the AWS managed common rule set, the
    known-bad-inputs set, and a rate limit.

    **~$5/month for the web ACL, +$1/month per rule group, +$0.60 per million
    requests.** Call it ~$8/month at this scale — which is more than the ALB
    and the Fargate tasks put together.

    Off by default because neither deployed service accepts a file upload,
    renders user-supplied HTML, or has an authentication surface to brute
    force. The rate limit is the part that would actually earn its keep, and it
    is the cheapest part of the thing you cannot buy separately.
  EOT
  type        = bool
  default     = false
}

variable "waf_rate_limit" {
  description = "Requests per 5 minutes from a single IP before WAF starts blocking it. 2000 is AWS's own default and is generous — the load test's stress profile peaks well under it."
  type        = number
  default     = 2000
}

variable "enable_access_logs" {
  description = <<-EOT
    ALB access logs to a dedicated S3 bucket.

    **~$0.50/month** at this request volume, plus PUT costs. Cheap, and still
    off by default: nginx already writes a structured JSON access log into
    CloudWatch, which carries the same request detail plus the upstream
    response time the ALB does not know about.

    Turn it on when you need what nginx cannot see — TLS negotiation failures,
    requests the ALB rejected before they reached a target, and the exact
    target a request was routed to.
  EOT
  type        = bool
  default     = false
}

variable "access_log_retention_days" {
  description = "Lifecycle expiry on the access log bucket. Logs that never expire are how an S3 bill grows without anyone deciding to spend the money."
  type        = number
  default     = 30
}

variable "waf_log_retention_days" {
  description = "Retention for the WAF log group. WAF logs every evaluated request when sampling is on, so this is volume — and volume is the cost."
  type        = number
  default     = 7
}
