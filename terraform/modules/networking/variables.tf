variable "name_prefix" {
  type = string
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "alb_listener_ports" {
  description = "Ports the ALB listens on publicly — one per deployed service."
  type        = list(number)
}

variable "task_ingress_port" {
  description = "Container port the ALB forwards to (nginx)."
  type        = number
  default     = 80
}

variable "operator_cidr" {
  description = "Operator's public IP in CIDR form, for the one-time DB bootstrap."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "availability_zones" {
  description = <<-EOT
    Exactly two AZ names, e.g. ["ap-south-1a", "ap-south-1b"]. Optional.

    Empty (the default) picks the first two the account can use. That is
    portable across regions and accounts, and it is also a value that can
    change underneath you — AZ ordering is per-account and AWS adds zones.
    Pin it when you want the same tfvars to rebuild the same stack.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) == 2
    error_message = "availability_zones must be empty or contain exactly two zone names: an ALB needs two subnets and RDS needs a subnet group spanning two."
  }
}

# Private networking.

variable "enable_private_subnets" {
  description = <<-EOT
    Put ECS tasks and RDS in private subnets with no route to the internet
    gateway. Requires either enable_nat_gateway or enable_vpc_endpoints, or the
    tasks cannot reach ECR and will never start.

    Cost on its own: $0. The subnets and route tables are free; what costs money
    is giving them a way out.
  EOT
  type        = bool
  default     = false
}

variable "enable_nat_gateway" {
  description = <<-EOT
    A NAT gateway per AZ, so private-subnet tasks can reach ECR, Secrets
    Manager and CloudWatch.

    **~$32/month per gateway, plus $0.045/GB processed.** With two AZs that is
    ~$64/month — roughly two and a half times the entire rest of this stack.
    Set single_nat_gateway = true to halve it and accept that one AZ losing its
    NAT takes out the tasks in that AZ.

    This is the single most common way an AWS bill surprises somebody. It is
    off by default for that reason, not because it is wrong.
  EOT
  type        = bool
  default     = false
}

variable "single_nat_gateway" {
  description = "One NAT gateway shared by both AZs instead of one each. Halves the cost and gives up cross-AZ independence. Only meaningful when enable_nat_gateway is true."
  type        = bool
  default     = true
}

variable "enable_vpc_endpoints" {
  description = <<-EOT
    VPC interface endpoints for ECR, Secrets Manager and CloudWatch Logs, plus
    a free S3 gateway endpoint. The other way to run private subnets without a
    NAT gateway.

    **~$7.20/month per interface endpoint per AZ.** Four interface endpoints
    across two AZs is ~$58/month. The S3 gateway endpoint is free.

    Cheaper than NAT only if egress is large; for this workload it is not. It
    is here because "use endpoints instead" is the standard follow-up question
    and the honest answer needs the number.
  EOT
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = <<-EOT
    VPC flow logs to CloudWatch.

    **~$0.50/GB ingested**, plus storage. For this traffic — two tasks and one
    database — that is cents a month, but it is per-GB on a metric that scales
    with traffic rather than with time.

    The security question flow logs answer is largely already answered by the
    security groups. They earn their keep when you need to prove what talked to
    what after the fact.
  EOT
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "Retention for the flow log group. Short by default — flow logs are volume, and volume is the cost."
  type        = number
  default     = 7
}

variable "nat_mode" {
  description = <<-EOT
    How private subnets reach the internet when enable_nat_gateway is on.

      "gateway"  ~$32/month per AZ. Managed, redundant within its AZ, no
                 instance to patch. The production-correct answer.
      "instance" ~$3/month. One t4g.nano doing NAT with source/destination
                 checks off.

    The instance is a SINGLE POINT OF FAILURE for outbound traffic and a host
    you are responsible for patching. For a stack that is destroyed between
    demos that is a reasonable trade; for anything with an SLA it is not.

    A tenfold cost difference is worth being able to choose, and worth saying
    plainly what the cheap option gives up.
  EOT
  type        = string
  default     = "gateway"

  validation {
    condition     = contains(["gateway", "instance"], var.nat_mode)
    error_message = "nat_mode must be \"gateway\" or \"instance\"."
  }
}

variable "nat_instance_type" {
  description = "t4g.nano is ARM, ~$3/month, and saturates well past what two Fargate tasks pulling images will generate."
  type        = string
  default     = "t4g.nano"
}
