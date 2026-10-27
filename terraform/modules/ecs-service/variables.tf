variable "name_prefix" { type = string }
variable "service_key" { type = string }
variable "aws_region" { type = string }
variable "cluster_arn" { type = string }
variable "subnet_ids" { type = list(string) }
variable "security_group_id" { type = string }
variable "target_group_arn" { type = string }
variable "execution_role_arn" { type = string }
variable "task_role_arn" { type = string }
variable "api_image_repository" { type = string }
variable "web_image_repository" { type = string }
variable "database_url_secret_arn" { type = string }
variable "public_url" { type = string }

variable "image_tag" {
  description = "Git SHA. Only the INITIAL tag Terraform deploys — after that the pipeline owns it (see the lifecycle block)."
  type        = string
  default     = "bootstrap"
}

variable "anthropic_secret_arn" {
  type    = string
  default = ""
}

variable "extra_environment" {
  type    = map(string)
  default = {}
}

variable "task_cpu" {
  type    = number
  default = 512
}

variable "task_memory" {
  type    = number
  default = 1024
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "use_fargate_spot" {
  type    = bool
  default = true
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "assign_public_ip" {
  description = "True in a public subnet (the default topology), false once private subnets give the task another route to ECR."
  type        = bool
  default     = true
}

# --- Connection pool ------------------------------------------------------- Values
# come from the db{} block in services/services.json, whose

variable "db_pool_size" {
  description = "Persistent connections per task. Peak usage is (pool_size + max_overflow) x desired_count x 2, because a rolling deploy runs at 200%."
  type        = number
  default     = 5
}

variable "db_max_overflow" {
  description = "Extra connections a task may open above pool_size under burst, returned afterwards."
  type        = number
  default     = 2
}

variable "db_pool_recycle_seconds" {
  description = "Recycle a pooled connection after this long. Must be BELOW the server's idle timeout, or the pool hands out sockets RDS has already closed and the failure lands on the next request to borrow one."
  type        = number
  default     = 1800
}

variable "db_pool_timeout_seconds" {
  description = "How long a request waits for a free connection before failing. Short on purpose: a request queueing 30s for a connection has already failed from the user's point of view, and holding it just converts an error into a timeout."
  type        = number
  default     = 10
}

variable "cpu_architecture" {
  description = "ARM64 (Graviton) is ~20% cheaper than X86_64 for the same work. The pipeline must build images for the matching platform."
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["ARM64", "X86_64"], var.cpu_architecture)
    error_message = "cpu_architecture must be ARM64 or X86_64."
  }
}

variable "enable_autoscaling" {
  description = "Target-tracking autoscaling on CPU. Off by default: min_capacity equals desired_count, so turning it on changes nothing until load arrives. Scaling out multiplies database connections — re-check the manifest's connection budget before raising max_capacity."
  type        = bool
  default     = false
}

variable "autoscaling_max_capacity" {
  description = "Ceiling for scale-out. 2 by default, which doubles the connection peak and still fits db.t3.micro's ~87 limit."
  type        = number
  default     = 2
}

variable "autoscaling_cpu_target" {
  description = "Average CPU to hold, as a percentage. 65 leaves headroom for a spike to be absorbed while the new task is still starting."
  type        = number
  default     = 65
}
