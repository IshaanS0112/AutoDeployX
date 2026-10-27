#!/usr/bin/env bash
# Deploy one service at one image tag. Called by .github/workflows/deploy.yml and
# rollback.yml, and runnable by hand.
set -euo pipefail

SERVICE_KEY="${SERVICE_KEY:?SERVICE_KEY is required (e.g. finsight)}"
IMAGE_TAG="${IMAGE_TAG:?IMAGE_TAG is required (an 8-char git SHA)}"
CLUSTER="${CLUSTER:?CLUSTER is required (the ECS cluster name)}"
AWS_REGION="${AWS_REGION:-ap-south-1}"
PROJECT="${PROJECT:-autodeployx}"

# How long to wait for the rollout to reach a terminal state. ECS's own
# circuit breaker gives up well before this; the timeout is a backstop against
# a job hanging until the runner is killed with no diagnosis in the log.
DEPLOY_TIMEOUT_SECONDS="${DEPLOY_TIMEOUT_SECONDS:-600}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-10}"

SERVICE_NAME="${CLUSTER}-${SERVICE_KEY}"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

log() { printf '%s  %s\n' "$(date -u +%H:%M:%S)" "$*"; }
group() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::group::$*"; else log "--- $* ---"; fi; }
endgroup() { if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi; }
emit() { [ -n "${GITHUB_OUTPUT:-}" ] && echo "$1=$2" >> "$GITHUB_OUTPUT"; log "output: $1=$2"; }

log "service=${SERVICE_NAME} tag=${IMAGE_TAG} cluster=${CLUSTER} region=${AWS_REGION}"

# --- 1. Capture the currently-deployed revision -----------------------------
# Recorded before anything changes so the log says what to roll back TO if this
# goes wrong and the circuit breaker somehow does not.
PREVIOUS_TASK_DEF="$(aws ecs describe-services \
  --cluster "$CLUSTER" --services "$SERVICE_NAME" \
  --query 'services[0].taskDefinition' --output text)"

if [ "$PREVIOUS_TASK_DEF" = "None" ] || [ -z "$PREVIOUS_TASK_DEF" ]; then
  echo "ERROR: service ${SERVICE_NAME} not found in cluster ${CLUSTER}." >&2
  echo "Has 'terraform apply' been run? See docs/setup.md." >&2
  exit 1
fi
log "currently deployed: ${PREVIOUS_TASK_DEF##*/}"

# --- 2. Build the new task definition revision ------------------------------
# Read the current one, swap the two image tags, strip the read-only fields the
# API returns but refuses to accept back, and register it.
group "Registering new task definition"

CURRENT_DEF="$(aws ecs describe-task-definition \
  --task-definition "$PREVIOUS_TASK_DEF" \
  --query 'taskDefinition' --output json)"

NEW_DEF="$(echo "$CURRENT_DEF" | jq \
  --arg api "${REGISTRY}/${PROJECT}/${SERVICE_KEY}-api:${IMAGE_TAG}" \
  --arg web "${REGISTRY}/${PROJECT}/${SERVICE_KEY}-web:${IMAGE_TAG}" \
  --arg sha "$IMAGE_TAG" '
  # Swap the image on each container, and keep GIT_SHA in the environment in
  # step with it so /health reports the truth.
  .containerDefinitions |= map(
    if .name == "api" then
      .image = $api
      | .environment = ((.environment // []) | map(select(.name != "GIT_SHA")) + [{name:"GIT_SHA", value:$sha}])
    elif .name == "web" then
      .image = $web
      | .environment = ((.environment // []) | map(select(.name != "GIT_SHA")) + [{name:"GIT_SHA", value:$sha}])
    else . end
  )
  # RegisterTaskDefinition rejects these — they are server-assigned metadata
  # that describe-task-definition returns for information.
  | del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
        .compatibilities, .registeredAt, .registeredBy, .deregisteredAt)
')"

NEW_TASK_DEF_ARN="$(aws ecs register-task-definition \
  --cli-input-json "$NEW_DEF" \
  --query 'taskDefinition.taskDefinitionArn' --output text)"

log "registered: ${NEW_TASK_DEF_ARN##*/}"
endgroup

# --- 3. Trigger the rollout -------------------------------------------------
group "Updating service"
# shellcheck disable=SC2016  # backticks are JMESPath, not command substitution
aws ecs update-service \
  --cluster "$CLUSTER" \
  --service "$SERVICE_NAME" \
  --task-definition "$NEW_TASK_DEF_ARN" \
  --query 'service.deployments[?status==`PRIMARY`].[id,rolloutState]' --output text
endgroup

# --- 4. Watch the rollout --------------------------------------------------- NOT
# `aws ecs wait services-stable`.
group "Waiting for rollout (timeout ${DEPLOY_TIMEOUT_SECONDS}s)"

deadline=$(( $(date +%s) + DEPLOY_TIMEOUT_SECONDS ))
final_state=""
last_reason=""

while [ "$(date +%s)" -lt "$deadline" ]; do
  # IFS must be a literal tab, not the default whitespace.
  # shellcheck disable=SC2016  # backticks are JMESPath, not command substitution
  IFS=$'\t' read -r state reason running desired <<<"$(aws ecs describe-services \
    --cluster "$CLUSTER" --services "$SERVICE_NAME" \
    --query 'services[0].deployments[?status==`PRIMARY`] | [0].[rolloutState, rolloutStateReason, runningCount, desiredCount]' \
    --output text)" || true

  [ "$reason" != "$last_reason" ] && { log "[$state] $reason"; last_reason="$reason"; }
  log "running=${running}/${desired} state=${state}"

  case "$state" in
    COMPLETED)
      final_state="COMPLETED"; break ;;
    FAILED)
      final_state="FAILED"; break ;;
    IN_PROGRESS)
      : ;;
    *)
      log "unexpected rolloutState: ${state}" ;;
  esac
  sleep "$POLL_INTERVAL_SECONDS"
done
endgroup

# --- 5. Report --------------------------------------------------------------
SERVICE_URL="$(aws elbv2 describe-load-balancers \
  --names "${CLUSTER}-alb" --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo "")"
LISTENER_PORT="$(jq -r --arg k "$SERVICE_KEY" \
  '.services[] | select(.key==$k) | .alb_listener_port' "$(dirname "$0")/../services/services.json")"
if [ -n "$SERVICE_URL" ] && [ "$SERVICE_URL" != "None" ]; then
  SERVICE_URL="http://${SERVICE_URL}:${LISTENER_PORT}"
  emit "service_url" "$SERVICE_URL"
fi
emit "task_definition" "$NEW_TASK_DEF_ARN"
emit "previous_task_definition" "$PREVIOUS_TASK_DEF"

case "$final_state" in
  COMPLETED)
    log "DEPLOYED — ${SERVICE_KEY} @ ${IMAGE_TAG} is serving traffic."
    emit "result" "deployed"
    exit 0
    ;;
  FAILED)
    cat >&2 <<EOF

  ================================================================
  DEPLOYMENT FAILED — the ECS circuit breaker tripped.
  ================================================================

  The new tasks did not pass their health checks, so ECS stopped the
  rollout and is redeploying the previous task definition:

      ${PREVIOUS_TASK_DEF##*/}

  The site should still be up on the previous version. Verify:
      curl -sf ${SERVICE_URL:-<alb-url>}/api/health

  Reason ECS gave: ${last_reason}

  Diagnose with docs/runbook.md, or straight to the logs:
      aws logs tail /ecs/${CLUSTER}/${SERVICE_KEY} --since 15m --follow

EOF
    emit "result" "rolled_back"
    exit 1
    ;;
  *)
    echo "ERROR: rollout did not reach a terminal state within ${DEPLOY_TIMEOUT_SECONDS}s." >&2
    echo "Last state: ${state:-unknown} — ${last_reason}" >&2
    echo "ECS may still be rolling. Check: aws ecs describe-services --cluster ${CLUSTER} --services ${SERVICE_NAME}" >&2
    emit "result" "timeout"
    exit 1
    ;;
esac
