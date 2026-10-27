output "service_urls" {
  description = "The live URLs. This is the point of the whole project."
  value       = module.alb.service_urls
}

output "alb_dns_name" {
  value = module.alb.dns_name
}

output "github_deploy_role_arn" {
  description = "Set as the AWS_DEPLOY_ROLE_ARN repository variable in GitHub. Not a secret."
  value       = module.iam.github_deploy_role_arn
}

output "ecr_repository_urls" {
  value = module.ecr.repository_urls
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "ecs_service_names" {
  value = { for k, m in module.service : k => m.service_name }
}

output "log_groups" {
  value = { for k, m in module.service : k => m.log_group_name }
}

output "rds_endpoint" {
  value = module.rds.endpoint
}

output "rds_master_secret_arn" {
  description = "Read by scripts/init-databases.sh. The password is never output."
  value       = module.rds.master_secret_arn
}

output "db_password_secret_arns" {
  value = module.rds.app_password_secret_arns
}

output "dashboard_url" {
  value = module.observability.dashboard_url
}

output "aws_region" {
  value = var.aws_region
}

output "deployed_services" {
  description = "Everything scripts/ and the workflows need, in one place."
  value = {
    for k, svc in local.services : k => {
      cluster        = aws_ecs_cluster.this.name
      service        = module.service[k].service_name
      task_family    = module.service[k].task_definition_family
      url            = module.alb.service_urls[k]
      health_url     = "${module.alb.service_urls[k]}${svc.health_path}"
      api_repository = module.ecr.repository_urls["${var.project}/${k}-api"]
      web_repository = module.ecr.repository_urls["${var.project}/${k}-web"]
      log_group      = module.service[k].log_group_name
      source_repo    = svc.repo
    }
  }
}

output "github_plan_role_arn" {
  description = "Read-only role for pull requests. Set as the repository variable AWS_PLAN_ROLE_ARN."
  value       = module.iam.github_plan_role_arn
}
