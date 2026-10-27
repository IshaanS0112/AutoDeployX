#!/usr/bin/env bash
# Run one service's schema migration as a one-off ECS task, from the SAME image the
# deploy is about to ship, and block until it succeeds or fails.
set -euo pipefail

SERVICE_KEY="${SERVICE_KEY:?SERVICE_KEY is required (e.g. strategysphere)}"
IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG is required (the git SHA being deployed)}"
CLUSTER="${CLUSTER:?CLUSTER is required (the ECS cluster name)}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
PROJECT="${PROJECT:-autodeployx}"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${REPO_ROOT}/services/services.json"

log()   { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
group() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::$*"; else log "--- $* ---"; fi; }
endgroup() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi; }
emit()  { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"; log "output: $1=$2"; }

svc="$(jq -c --arg k "$SERVICE_KEY" '.services[] | select(.key==$k)' "$MANIFEST")"
[ -n "$svc" ] || { echo "Unknown service '${SERVICE_KEY}'." >&2; exit 1; }

ENABLED="$(echo "$svc" | jq -r '.migrations.enabled')"
TIMEOUT="$(echo "$svc" | jq -r '.migrations.timeout_seconds')"

if [ "$ENABLED" != "true" ]; then
  # Not an error. The manifest records which repos have adopted migrations, the
  # same way checks.lint records which have adopted a linter — and it records
  # what is TRUE today rather than what is intended.
  log "migrations are not enabled for ${SERVICE_KEY}; skipping."
  echo "::warning title=No migration stage::${SERVICE_KEY} still relies on create_all() at startup. create_all only ADDS tables — it will not alter a column, so the first non-additive schema change deploys silently and fails at runtime. See docs/adr/0016."
  emit "result" "skipped"
  exit 0
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
FAMILY="${CLUSTER}-${SERVICE_KEY}-migrate"
LOG_GROUP="/ecs/${CLUSTER}/${SERVICE_KEY}-migrate"

log "service=${SERVICE_KEY} tag=${IMAGE_TAG} family=${FAMILY} timeout=${TIMEOUT}s"

# --- Network placement, read from the service itself ------------------------
# Rather than duplicating subnet and security-group ids here, take them from the
# service that is about to be.
group "Resolving network configuration"
NETWORK_JSON="$(aws ecs describe-services \
  --cluster "$CLUSTER" --services "${CLUSTER}-${SERVICE_KEY}" \
  --query 'services[0].networkConfiguration.awsvpcConfiguration' --output json)"

if [ -z "$NETWORK_JSON" ] || [ "$NETWORK_JSON" = "null" ]; then
  echo "ERROR: could not read network configuration from ${CLUSTER}-${SERVICE_KEY}." >&2
  echo "Has 'terraform apply' been run? See docs/setup.md." >&2
  exit 1
fi
echo "$NETWORK_JSON" | jq -c '{subnets, securityGroups, assignPublicIp}'
endgroup

# --- Pin the image to the SHA being deployed -------------------------------- The
# registered task definition carries whatever tag Terraform put there.
group "Registering migration revision @ ${IMAGE_TAG}"
CURRENT_DEF="$(aws ecs describe-task-definition --task-definition "$FAMILY" \
  --query 'taskDefinition' --output json)"

NEW_DEF="$(echo "$CURRENT_DEF" | jq \
  --arg img "${REGISTRY}/${PROJECT}/${SERVICE_KEY}-api:${IMAGE_TAG}" \
  --arg sha "$IMAGE_TAG" '
  .containerDefinitions |= map(
    .image = $img
    | .environment = ((.environment // []) | map(select(.name != "GIT_SHA")) + [{name:"GIT_SHA", value:$sha}])
  )
  | del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
        .compatibilities, .registeredAt, .registeredBy, .deregisteredAt)')"

TASK_DEF_ARN="$(aws ecs register-task-definition --cli-input-json "$NEW_DEF" \
  --query 'taskDefinition.taskDefinitionArn' --output text)"
log "registered: ${TASK_DEF_ARN##*/}"
endgroup

# --- Run it -----------------------------------------------------------------
group "Running migration"
TASK_ARN="$(aws ecs run-task \
  --cluster "$CLUSTER" \
  --task-definition "$TASK_DEF_ARN" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration=$(echo "$NETWORK_JSON" | jq -c '{subnets, securityGroups, assignPublicIp}')" \
  --started-by "migrate-${IMAGE_TAG}" \
  --query 'tasks[0].taskArn' --output text)"

if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" = "None" ]; then
  echo "ERROR: RunTask returned no task. Check the IAM policy allows ecs:RunTask on ${FAMILY}." >&2
  exit 1
fi
TASK_ID="${TASK_ARN##*/}"
log "task ${TASK_ID} started"

deadline=$(( $(date +%s) + TIMEOUT ))
status=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  # IFS must be a literal tab: --output text is tab-delimited and stoppedReason
  # is an English sentence, so the default IFS splits it across fields. Same
  # trap as deploy.sh.
  IFS=$'\t' read -r status exit_code reason <<<"$(aws ecs describe-tasks \
    --cluster "$CLUSTER" --tasks "$TASK_ARN" \
    --query 'tasks[0].[lastStatus, containers[0].exitCode, stoppedReason]' \
    --output text)" || true

  [ "$status" = "STOPPED" ] && break
  log "status=${status}"
  sleep 5
done
endgroup

# --- Always show the logs ---------------------------------------------------
# On success as well as failure. A migration that reported success and applied
# nothing is a thing worth being able to see.
group "Migration output"
aws logs tail "$LOG_GROUP" --since 10m --format short 2>/dev/null \
  | grep -F "$TASK_ID" || aws logs tail "$LOG_GROUP" --since 10m --format short 2>/dev/null || true
endgroup

if [ "$status" != "STOPPED" ]; then
  echo "ERROR: migration did not finish within ${TIMEOUT}s. Stopping it." >&2
  echo "       A hung migration holds a lock on the schema and blocks the next deploy." >&2
  aws ecs stop-task --cluster "$CLUSTER" --task "$TASK_ARN" \
    --reason "timed out after ${TIMEOUT}s" >/dev/null || true
  emit "result" "timeout"
  exit 1
fi

if [ "${exit_code:-1}" != "0" ]; then
  cat >&2 <<EOF

  ================================================================
  MIGRATION FAILED — exit code ${exit_code:-unknown}
  ================================================================

  The deploy has NOT proceeded. The previous revision is still serving
  traffic, and the schema it expects is still the schema in place.

  Reason ECS gave: ${reason:-none}

  Diagnose:
      aws logs tail ${LOG_GROUP} --since 30m

  A failed migration is usually one of:
    - the migration itself errored   -> fix it, push again
    - it could not reach the database -> check the task security group
    - a lock was already held         -> another migration is mid-flight

  If a PARTIAL migration was applied, the schema is now between revisions.
  Roll it forward with a fix rather than back: see docs/adr/0016 on
  expand-migrate-contract, which exists so this state is survivable.

EOF
  emit "result" "failed"
  exit 1
fi

log "MIGRATED — ${SERVICE_KEY} schema is at head for ${IMAGE_TAG}."
emit "result" "migrated"
emit "task_definition" "$TASK_DEF_ARN"
