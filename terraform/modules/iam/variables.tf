variable "name_prefix" {
  type = string
}

variable "create_oidc_provider" {
  description = "False if the account already has a GitHub OIDC provider — there can be only one per issuer per account, and a second apply would fail with EntityAlreadyExists."
  type        = bool
  default     = true
}

variable "existing_oidc_provider_arn" {
  description = "Used when create_oidc_provider is false."
  type        = string
  default     = ""
}

variable "allowed_subjects" {
  description = "OIDC `sub` claims permitted to assume the deploy role."
  type        = list(string)
}

variable "ecr_repository_arns" {
  type = list(string)
}

variable "ecs_service_arns" {
  type = list(string)
}

variable "ecs_cluster_arn" {
  type = string
}

variable "secret_arns" {
  description = "Secrets Manager ARNs the execution role may read. Scoped to this project."
  type        = list(string)
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "migration_task_definition_arns" {
  description = "Family ARNs (with :* for the revision) of the one-off migration task definitions the pipeline may RunTask."
  type        = list(string)
  default     = []
}

variable "plan_allowed_subjects" {
  description = "OIDC sub claims allowed to assume the READ-ONLY plan role. Pull requests, which the deploy role's trust policy deliberately excludes."
  type        = list(string)
  default     = []
}

variable "state_bucket_arns" {
  description = "State bucket and its objects, so a plan can read state and take a lock. S3-native locking means a write to the lockfile, which is why PutObject and DeleteObject are here."
  type        = list(string)
  default     = ["*"]
}

variable "plan_readable_iam_arns" {
  description = "IAM ARNs the read-only plan role may read \u2014 this project's own roles and OIDC provider, not the account's."
  type        = list(string)
  default     = ["*"]
}
