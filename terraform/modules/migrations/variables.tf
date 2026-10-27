variable "name_prefix" { type = string }
variable "service_key" { type = string }
variable "aws_region" { type = string }
variable "execution_role_arn" { type = string }
variable "task_role_arn" { type = string }
variable "api_image_repository" { type = string }
variable "database_url_secret_arn" { type = string }

variable "image_tag" {
  description = "Only the initial tag. scripts/migrate.sh overrides it per run with the SHA being deployed, so the migration always runs from the image about to ship."
  type        = string
  default     = "bootstrap"
}

variable "migration_command" {
  description = "From services.json — e.g. [\"alembic\", \"upgrade\", \"head\"]."
  type        = list(string)
  default     = ["alembic", "upgrade", "head"]
}

variable "task_cpu" {
  description = "256 units. A migration is IO-bound against the database; the service's allocation would just cost more for the seconds it runs."
  type        = number
  default     = 256
}

variable "task_memory" {
  type    = number
  default = 512
}

variable "log_retention_days" {
  type    = number
  default = 7
}

variable "tags" {
  type    = map(string)
  default = {}
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
