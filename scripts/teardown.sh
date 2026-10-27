#!/usr/bin/env bash
# terraform destroy, with the guardrails that make it safe to run casually.
set -euo pipefail

cd "$(dirname "$0")/.."
TF_DIR="terraform"
AUTO=false
[ "${1:-}" = "--yes" ] && AUTO=true

# Which environment. Defaults to production so the unqualified command still
# means what it always meant.
ENVIRONMENT="${ENVIRONMENT:-production}"
VAR_FILE="envs/${ENVIRONMENT}.tfvars"
VAR_ARGS=()
if [ -f "${TF_DIR}/${VAR_FILE}" ]; then
  VAR_ARGS=(-var-file="$VAR_FILE")
elif [ -f "${TF_DIR}/terraform.tfvars" ]; then
  # The single-environment layout, still supported.
  VAR_ARGS=()
else
  echo "ERROR: no ${TF_DIR}/${VAR_FILE} and no ${TF_DIR}/terraform.tfvars." >&2
  echo "       Copy ${VAR_FILE}.example, or set ENVIRONMENT to one that exists." >&2
  exit 1
fi

command -v terraform >/dev/null || { echo "terraform not on PATH" >&2; exit 1; }

echo "About to DESTROY the AutoDeployX ${ENVIRONMENT} stack."
echo

terraform -chdir="$TF_DIR" plan -destroy -no-color -input=false "${VAR_ARGS[@]}" \
  | grep -E '^  # ' | sed 's/^  # /  - /' || true

echo
cat <<EOF
This removes: ECS services and tasks, the ALB and its listeners, the RDS
instance (skip_final_snapshot = true, so THE DATA IS GONE), Secrets Manager
entries, ECR repositories AND THE IMAGES IN THEM (force_delete = true), the
VPC, CloudWatch log groups and alarms, and the IAM roles.

This does NOT remove: the S3 state bucket or the DynamoDB lock table. Both are
protected with prevent_destroy, because losing them is worse than any bill.

Budget alarms are destroyed too. If you are tearing down because of cost,
re-apply them alone afterwards:
    make budgets ENV=${ENVIRONMENT}
EOF
echo

if [ "$AUTO" = false ]; then
  # The environment name, not a generic word. Typing "destroy" while looking at
  # the wrong terminal is a mistake that has happened to everyone; typing
  # "destroy production" requires having read which stack this is.
  read -rp "Type 'destroy ${ENVIRONMENT}' to proceed: " answer
  [ "$answer" = "destroy ${ENVIRONMENT}" ] || { echo "Aborted."; exit 1; }
fi

# Deletion protection would block the RDS destroy. It defaults to false in this
# project precisely so teardown works unattended, but check rather than fail
# ten minutes in.
if terraform -chdir="$TF_DIR" output -json 2>/dev/null | jq -e '.rds_endpoint' >/dev/null 2>&1; then
  echo "Note: if destroy fails on the DB instance, set rds_deletion_protection = false and re-apply first."
fi

terraform -chdir="$TF_DIR" destroy -auto-approve -input=false "${VAR_ARGS[@]}"

echo
echo "Destroyed. Verify nothing is still billing:"
echo "  aws ecs list-clusters"
echo "  aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName'"
echo "  aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier'"
echo "  aws ec2 describe-nat-gateways --query 'NatGateways[?State==\`available\`].NatGatewayId'"
echo
echo "The last one should always be empty — this project never creates a NAT gateway."
