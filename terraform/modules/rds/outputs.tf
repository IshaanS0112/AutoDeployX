output "endpoint" {
  value = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "identifier" {
  value = aws_db_instance.this.identifier
}

output "master_secret_arn" {
  value = aws_secretsmanager_secret.master.arn
}

output "database_url_secret_arns" {
  description = "service key -> ARN of the secret holding its DATABASE_URL."
  value       = { for k, v in aws_secretsmanager_secret.database_url : k => v.arn }
}

output "app_password_secret_arns" {
  value = { for k, v in aws_secretsmanager_secret.app_password : k => v.arn }
}

output "all_secret_arns" {
  description = "Everything the task execution role needs read access to."
  value = concat(
    [aws_secretsmanager_secret.master.arn],
    [for v in aws_secretsmanager_secret.database_url : v.arn],
    [for v in aws_secretsmanager_secret.app_password : v.arn],
  )
}
