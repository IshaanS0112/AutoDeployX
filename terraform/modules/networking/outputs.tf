output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = [for s in aws_subnet.public : s.id]
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "tasks_security_group_id" {
  value = aws_security_group.tasks.id
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}

output "private_subnet_ids" {
  description = "Empty unless enable_private_subnets is true."
  value       = [for s in aws_subnet.private : s.id]
}

output "workload_subnet_ids" {
  description = <<-EOT
    Where ECS tasks and RDS actually go. Private subnets when they exist,
    public otherwise.

    This is the output the root module consumes, so flipping
    enable_private_subnets moves the workload without any other module
    knowing that the topology changed.
  EOT
  value       = local.private_enabled ? [for s in aws_subnet.private : s.id] : [for s in aws_subnet.public : s.id]
}

output "assign_public_ip" {
  description = "Whether ECS tasks need a public IP. False once there is a NAT gateway or endpoints to reach AWS services through."
  value       = !local.private_enabled
}

output "private_networking_enabled" {
  value = local.private_enabled
}

output "nat_gateway_count" {
  description = "How many NAT gateways exist. Multiply by ~$32/month."
  value       = length(aws_nat_gateway.this)
}

output "interface_endpoint_count" {
  description = "How many interface endpoints exist. Multiply by ~$7.20/month per AZ."
  value       = length(aws_vpc_endpoint.interface)
}
