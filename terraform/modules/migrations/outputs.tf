output "task_definition_arn" {
  value = aws_ecs_task_definition.this.arn
}

output "task_definition_family" {
  description = "What scripts/migrate.sh passes to RunTask, and what the IAM policy is scoped to."
  value       = aws_ecs_task_definition.this.family
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.this.name
}
