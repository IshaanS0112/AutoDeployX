output "github_deploy_role_arn" {
  description = "Put this in the workflow's role-to-assume. It is not a secret — it is useless without a matching OIDC token."
  value       = aws_iam_role.github_deploy.arn
}

output "github_plan_role_arn" {
  description = "Read-only role for pull requests. Set as the repository variable AWS_PLAN_ROLE_ARN."
  value       = aws_iam_role.github_plan.arn
}

output "ecs_task_execution_role_arn" {
  value = aws_iam_role.ecs_task_execution.arn
}

output "ecs_task_role_arn" {
  value = aws_iam_role.ecs_task.arn
}

output "oidc_provider_arn" {
  value = local.oidc_provider_arn
}
