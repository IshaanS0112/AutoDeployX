output "state_bucket" {
  value = aws_s3_bucket.state.id
}

output "backend_config" {
  description = "Paste into terraform/backend.hcl, or let scripts/bootstrap-state.sh write it for you."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.id}"
    key          = "autodeployx/production/terraform.tfstate"
    region       = "${var.aws_region}"
    use_lockfile = true
    encrypt      = true
  EOT
}
