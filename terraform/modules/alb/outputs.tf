output "dns_name" {
  description = "The public hostname. This is the live URL."
  value       = aws_lb.this.dns_name
}

output "arn" {
  value = aws_lb.this.arn
}

output "arn_suffix" {
  description = "Needed for CloudWatch metric dimensions (LoadBalancer)."
  value       = aws_lb.this.arn_suffix
}

output "target_group_arns" {
  value = { for k, v in aws_lb_target_group.this : k => v.arn }
}

output "target_group_arn_suffixes" {
  description = "CloudWatch metric dimension (TargetGroup)."
  value       = { for k, v in aws_lb_target_group.this : k => v.arn_suffix }
}

output "service_urls" {
  description = "One clickable URL per service. https://<key>.<domain> when a domain is configured, http://<alb>:<port> otherwise."
  value = {
    for k, v in var.services : k => (
      local.tls_enabled
      ? "https://${local.service_fqdns[k]}"
      : "http://${aws_lb.this.dns_name}:${v.listener_port}"
    )
  }
}

output "tls_enabled" {
  description = "Whether the stack is serving HTTPS. Read by docs and by the smoke test's URL construction."
  value       = local.tls_enabled
}

output "certificate_arn" {
  description = "ACM certificate ARN, or empty when running plain HTTP."
  value       = local.tls_enabled ? aws_acm_certificate_validation.this[0].certificate_arn : ""
}
