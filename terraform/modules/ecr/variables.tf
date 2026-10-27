variable "repositories" {
  description = "Set of ECR repository names to create, e.g. { \"autodeployx/finsight-api\" = {} }."
  type        = map(object({}))
}

variable "keep_last_images" {
  description = "How many tagged images to retain. 10 covers a rollback window of several days of pushes."
  type        = number
  default     = 10
}

variable "force_delete" {
  description = "Allow `terraform destroy` to delete repositories that still contain images. True here because teardown is a routine operation in this project."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}
