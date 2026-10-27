#!/usr/bin/env bash
# Step 1 of setup: create the S3 bucket and DynamoDB lock table that hold the main
# stack's state, then write terraform/backend.<env>.hcl from the outputs.
set -euo pipefail

cd "$(dirname "$0")/.."
REGION="${AWS_REGION:-ap-south-1}"
ENVIRONMENT="${1:-production}"
PROJECT="${PROJECT:-autodeployx}"

case "$ENVIRONMENT" in
  [a-z0-9-]*) ;;
  *) echo "ERROR: environment name must be lowercase alphanumeric with dashes: got '${ENVIRONMENT}'" >&2; exit 1 ;;
esac

command -v terraform >/dev/null || { echo "terraform not on PATH" >&2; exit 1; }

echo "==> Creating the Terraform state backend (local state, by necessity)"
echo "    region=${REGION} environment=${ENVIRONMENT}"

# The bootstrap stack itself is idempotent: running it again for a second
# environment finds the bucket and table already there and changes nothing.
terraform -chdir=terraform/bootstrap init -input=false
terraform -chdir=terraform/bootstrap apply -auto-approve -input=false -var="aws_region=${REGION}"

BUCKET="$(terraform -chdir=terraform/bootstrap output -raw state_bucket)"

BACKEND_FILE="terraform/backend.${ENVIRONMENT}.hcl"

cat > "$BACKEND_FILE" <<EOF
bucket       = "${BUCKET}"
key          = "${PROJECT}/${ENVIRONMENT}/terraform.tfstate"
region       = "${REGION}"
use_lockfile = true
encrypt      = true
EOF

# Kept for backwards compatibility with anything that still says
# `-backend-config=backend.hcl`, and because production is the common case.
if [ "$ENVIRONMENT" = "production" ]; then
  cp "$BACKEND_FILE" terraform/backend.hcl
fi

echo
echo "Wrote ${BACKEND_FILE}:"
cat "$BACKEND_FILE"
echo
echo "Set these as GitHub repository VARIABLES (Settings -> Secrets and variables -> Actions -> Variables):"
echo "  TF_STATE_BUCKET = ${BUCKET}"
echo
echo "Next:"
echo "  make init ENV=${ENVIRONMENT}"
echo "or, without make:"
echo "  terraform -chdir=terraform init -reconfigure -backend-config=backend.${ENVIRONMENT}.hcl"
echo
echo "-reconfigure matters when switching environments. Without it Terraform"
echo "offers to MIGRATE the existing state into the new key, which reads like a"
echo "routine prompt and is not."
