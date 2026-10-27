output "repository_urls" {
  description = "Map of repository name -> registry URL, used by the pipeline to tag and push."
  value       = { for k, v in aws_ecr_repository.this : k => v.repository_url }
}

output "repository_arns" {
  description = "Used to scope the GitHub Actions push permissions to exactly these repos."
  value       = [for v in aws_ecr_repository.this : v.arn]
}
