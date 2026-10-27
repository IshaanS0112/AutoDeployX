# Remote state in S3 with a DynamoDB lock table.
terraform {
  backend "s3" {
    key = "autodeployx/production/terraform.tfstate"

    # S3-native locking (Terraform >= 1.11): a .tflock object beside the state
    # file, taken with a conditional put. No DynamoDB table.
    use_lockfile = true
    encrypt      = true
    # bucket and region come from -backend-config=backend.hcl.
  }
}
