# State backend bootstrap.

terraform {
  required_version = ">= 1.11.0"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.60" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
  # Local state on purpose. See above.
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Purpose   = "terraform-state-backend"
    }
  }
}

# S3 bucket names are globally unique across every AWS account on earth, so
# "autodeployx-tfstate" is long gone.
resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "state" {
  bucket = "${var.project}-tfstate-${random_id.suffix.hex}"

  # This bucket is the record of what exists in the account.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    # Every state write keeps the previous version.
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# State contains resource attributes in plaintext, including things you would
# not want public. This bucket must never be readable by anyone but the account.
resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      # Keep 90 days of state history. Versioning without expiry means paying
      # to store every state file you have ever written, forever.
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# No DynamoDB lock table.
#
# Terraform 1.10 added native S3 state locking: it writes a .tflock object
# beside the state file and takes the lock with a conditional put, which S3
# makes atomic. 1.11 made it stable.
#
# That removes a whole resource from the bootstrap stack, a second thing to
# forget on teardown, and a second thing to grant in every IAM policy. The
# guarantee is the same one DynamoDB gave: two concurrent applies cannot both
# proceed.
#
# The trade: it needs Terraform >= 1.11 everywhere, including CI. The version
# constraint above is what enforces that, and a stale terraform silently
# falling back to no locking is the failure this prevents.
