variable "project" {
  description = "Name prefix for every resource. Also the ECS cluster name."
  type        = string
  default     = "autodeployx"
}

variable "environment" {
  description = "Deployment environment. V1 runs a single one; the variable exists so a second is a tfvars file rather than a refactor."
  type        = string
  default     = "production"
}

variable "aws_region" {
  description = "AWS region. ap-south-1 (Mumbai) is closest to the operator."
  type        = string
  default     = "ap-south-1"
}

variable "github_owner" {
  description = "GitHub account that owns the pipeline repo — used to scope the OIDC trust policy."
  type        = string
  default     = "IshaanS0112"
}

variable "github_repo" {
  description = "Repo allowed to assume the deploy role. Scoped as repo:<owner>/<repo>:* in the trust policy."
  type        = string
  default     = "AutoDeployX"
}

variable "github_allowed_refs" {
  description = <<-EOT
    Which refs of the repo may assume the deploy role. Defaults to the main
    branch and the `production` GitHub environment only.

    This is the whole point of OIDC: a pull request from a fork runs with
    `repo:owner/repo:pull_request` as its subject and therefore cannot assume
    this role at all, no matter what its workflow file says.
  EOT
  type        = list(string)
  default = [
    "repo:IshaanS0112/AutoDeployX:ref:refs/heads/main",
    "repo:IshaanS0112/AutoDeployX:environment:production",
  ]
}

variable "operator_cidr" {
  description = <<-EOT
    Your public IP in CIDR form (e.g. "203.0.113.42/32"), for direct psql
    access to RDS during the one-time database bootstrap.

    Leaving this at 0.0.0.0/0 opens the database port to the internet. It is
    still password-protected, but do not do it. `curl -s ifconfig.me` gives you
    the value; re-apply when your address changes.
  EOT
  type        = string

  validation {
    condition     = can(cidrnetmask(var.operator_cidr))
    error_message = "operator_cidr must be valid CIDR notation, e.g. 203.0.113.42/32."
  }
}

variable "budget_thresholds_usd" {
  description = "Monthly cost thresholds that trigger an email alert. Created BEFORE any billable resource."
  type        = list(number)
  default     = [5, 10, 20]
}

variable "budget_notification_email" {
  description = "Where budget alerts go. Required — the alarms are not optional in this project."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.budget_notification_email))
    error_message = "budget_notification_email must be a valid email address."
  }
}

variable "alert_email" {
  description = "Where CloudWatch alarm notifications go. Defaults to the budget address."
  type        = string
  default     = ""
}

# --- Cost levers ----------------------------------------------------------- Every
# one of these exists because it moves the monthly bill.

variable "use_fargate_spot" {
  description = "Run tasks on FARGATE_SPOT (~70% cheaper). Spot tasks can be reclaimed with a 2-minute warning; the service replaces them. Correct for a portfolio deployment, wrong for anything with an SLA."
  type        = bool
  default     = true
}

variable "enable_container_insights" {
  description = "ECS Container Insights. Off by default — it publishes custom metrics that are NOT free-tier eligible and cost **~$3-8/month** at this scale, which can exceed the compute it observes."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention. 7 days keeps ingestion inside the free tier for this traffic level; `never expire` is how log bills grow quietly."
  type        = number
  default     = 7
}

variable "rds_instance_class" {
  description = "db.t3.micro is free-tier eligible for 12 months from account creation."
  type        = string
  default     = "db.t3.micro"
}

variable "rds_allocated_storage" {
  description = "GB. Free tier covers 20."
  type        = number
  default     = 20
}

variable "rds_deletion_protection" {
  description = "false so `terraform destroy` actually works. Production would be true; this project is torn down between demos on purpose."
  type        = bool
  default     = false
}

variable "rds_backup_retention_days" {
  description = "1 day. Free-tier backup storage is capped at the size of the DB, and 0 would mean no point-in-time recovery at all."
  type        = number
  default     = 1
}

variable "anthropic_api_key" {
  description = <<-EOT
    Optional. Written into Secrets Manager and injected into the task at
    runtime by the ECS agent — never baked into an image and never a plaintext
    value in the task definition.

    Both services degrade gracefully without it: every ratio, Z-score and
    strategy score is computed identically, only the LLM narration falls back
    to a deterministic template. Leave empty and the deployment still works.

    Pass it via TF_VAR_anthropic_api_key, not a committed tfvars file.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

# --- TLS (optional) --------------------------------------------------------

variable "domain_name" {
  description = <<-EOT
    A domain you control, e.g. "example.com". Optional.

    Empty (the default) keeps the stack on plain HTTP with one listener port
    per service — :80 for the first service, :8080 for the second. That is the
    documented tradeoff: an ALB can redirect but cannot rewrite a path prefix,
    and both frontends are SPAs served from the root of their origin, so
    path-based routing is not available without rebuilding them.

    Set this together with route53_zone_id and the stack switches to the shape
    it should have: one ACM certificate, HTTPS on :443, each service at
    <key>.<domain>, and :80 permanently redirecting. The per-port listeners
    disappear along with the :8080 oddity.
  EOT
  type        = string
  default     = ""
}

variable "route53_zone_id" {
  description = "Route 53 hosted zone id for domain_name. Required when domain_name is set; ACM DNS validation and the service ALIAS records are written into it."
  type        = string
  default     = ""
}

# --- SLO -------------------------------------------------------------------

variable "availability_slo" {
  description = <<-EOT
    Target availability, as a fraction. Drives the error-budget burn-rate
    alarms in the observability module.

    99% by default, and deliberately not higher. This is one task on Fargate
    Spot behind one ALB with a single-AZ database. 99.9% is 43 minutes of
    downtime a month; a Spot reclaim alone can spend a chunk of that. Publishing
    a number the architecture cannot meet is how an SLO becomes an alert people
    mute.
  EOT
  type        = number
  default     = 0.99
}

variable "enable_slo_alarms" {
  description = "Burn-rate alarms. Metric math over ALB metrics AWS already publishes, so they add nothing to the bill."
  type        = bool
  default     = true
}

variable "enable_cost_anomaly_detection" {
  description = "AWS Cost Anomaly Detection alongside the fixed budgets. Free. Catches spend that changes shape before it crosses a threshold."
  type        = bool
  default     = true
}

variable "availability_zones" {
  description = "Exactly two AZ names, or empty to pick the first two the account can use. Pin it when reproducibility matters more than portability."
  type        = list(string)
  default     = []
}

# THE EXPENSIVE SWITCHES Everything in this block is OFF by default, and the default
# apply is byte-identical to the stack documented in

variable "enable_private_subnets" {
  description = "Move ECS tasks and RDS into private subnets. $0 on its own, but useless without NAT or endpoints below. This is the production-correct topology; the default is the cheap one."
  type        = bool
  default     = false
}

variable "enable_nat_gateway" {
  description = "NAT gateway so private-subnet tasks can reach ECR. **~$32/month each**, plus $0.045/GB. The single most common surprise line on an AWS bill."
  type        = bool
  default     = false
}

variable "single_nat_gateway" {
  description = "One NAT shared across both AZs instead of one each. Halves the cost, gives up cross-AZ independence."
  type        = bool
  default     = true
}

variable "enable_vpc_endpoints" {
  description = "Interface endpoints for ECR, Logs, Secrets Manager and ECS Exec instead of a NAT gateway. **~$7.20/month per endpoint per AZ** — about $58/month for five across two AZs. Cheaper than NAT only when egress is large; here it is not."
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "VPC flow logs to CloudWatch. **~$0.50/GB ingested.** Cents a month at this traffic, but it scales with traffic rather than time."
  type        = bool
  default     = false
}

variable "enable_waf" {
  description = "WAFv2 in front of the ALB: AWS managed common + known-bad-inputs rule sets, plus a per-IP rate limit. **~$8/month all in** — more than the ALB and the Fargate tasks combined."
  type        = bool
  default     = false
}

variable "enable_alb_access_logs" {
  description = "ALB access logs to a dedicated S3 bucket. **~$0.50/month.** nginx's JSON log already covers most of what these show; these add what nginx cannot see, like requests the ALB rejected before they reached a target."
  type        = bool
  default     = false
}

variable "rds_multi_az" {
  description = "Synchronous standby with automatic failover. **~2x the RDS line — about +$12/month** on db.t3.micro, and the free tier does not cover the standby."
  type        = bool
  default     = false
}

variable "rds_performance_insights" {
  description = "Per-query wait-state analysis. Free at 7-day retention on most classes; **~$2-5/month** beyond that."
  type        = bool
  default     = false
}

variable "rds_enhanced_monitoring_interval" {
  description = "OS-level RDS metrics, in seconds (0 = off; 1/5/10/15/30/60). **Billed per instance per minute** — roughly $2-5/month at 60s."
  type        = number
  default     = 0
}

variable "cpu_architecture" {
  description = "ARM64 (Graviton) or X86_64. ARM64 is ~20% cheaper; the pipeline builds images to match. Changing this alone, without the matching image platform, fails at task start with an exec format error."
  type        = string
  default     = "ARM64"
}

variable "enable_autoscaling" {
  description = "Target-tracking CPU autoscaling for the ECS services. Off by default. Fargate Spot is billed per task-second, so the cost is whatever scale-out actually runs \u2014 roughly $0.010/hour per extra task."
  type        = bool
  default     = false
}

variable "autoscaling_max_capacity" {
  description = "Scale-out ceiling per service. Raising it multiplies the database connection peak; re-run `make lint` after changing it."
  type        = number
  default     = 2
}

variable "github_plan_allowed_refs" {
  description = <<-EOT
    OIDC subjects allowed to assume the READ-ONLY plan role.

    Pull requests and the scheduled drift check, which github_allowed_refs
    deliberately excludes.

    A fork's pull_request subject is identical to a branch PR's, so the trust
    policy CANNOT tell them apart. Read-only is not the same as safe to hand a
    stranger: this policy can enumerate IAM roles and EC2 metadata across the
    account, which is reconnaissance. The workflow therefore still skips the
    plan job for forks — the role is the second layer, not the only one.
  EOT
  type        = list(string)
  default = [
    "repo:IshaanS0112/AutoDeployX:pull_request",
    # The weekly drift check also only plans. A read-only role assumable from
    # main is harmless, and it keeps a scheduled job that runs unattended out
    # of the deploy role entirely.
    "repo:IshaanS0112/AutoDeployX:ref:refs/heads/main",
  ]
}

variable "nat_mode" {
  description = "\"gateway\" (~$32/month per AZ, managed) or \"instance\" (~$3/month, one t4g.nano, a single point of failure you patch yourself). Only meaningful when enable_nat_gateway is true."
  type        = string
  default     = "gateway"
}
