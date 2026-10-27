#!/usr/bin/env bash
# Validate services/services.json — the single source of truth that both the GitHub
# Actions matrix and Terraform read (§4.1).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${1:-${REPO_ROOT}/services/services.json}"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

fail() { echo "MANIFEST INVALID: $*" >&2; exit 1; }

# Fargate only accepts specific cpu/memory pairings. Getting this wrong is not
# caught until RegisterTaskDefinition rejects it, which happens mid-deploy.
valid_fargate_combo() {
  local cpu="$1" mem="$2"
  case "$cpu" in
    256)  [ "$mem" = 512 ] || [ "$mem" = 1024 ] || [ "$mem" = 2048 ] ;;
    512)  [ "$mem" -ge 1024 ] && [ "$mem" -le 4096 ] && [ $((mem % 1024)) -eq 0 ] ;;
    1024) [ "$mem" -ge 2048 ] && [ "$mem" -le 8192 ] && [ $((mem % 1024)) -eq 0 ] ;;
    2048) [ "$mem" -ge 4096 ] && [ "$mem" -le 16384 ] && [ $((mem % 1024)) -eq 0 ] ;;
    4096) [ "$mem" -ge 8192 ] && [ "$mem" -le 30720 ] && [ $((mem % 1024)) -eq 0 ] ;;
    *) return 1 ;;
  esac
}

validate() {
  local file="$1"

  [ -f "$file" ] || fail "no such file: ${file}"
  jq -e . "$file" >/dev/null 2>&1 || fail "not valid JSON"
  jq -e '.services | type == "array" and length > 0' "$file" >/dev/null \
    || fail ".services must be a non-empty array"

  # Every field Terraform or a workflow indexes into must be present and of the
  # right type.
  jq -e '(.services|length) as $n
         | [.services[] | select(
             (.key|type=="string") and (.key|test("^[a-z0-9][a-z0-9-]*$")) and
             (.repo|type=="string") and (.ref|type=="string") and
             (.display_name|type=="string") and
             (.alb_listener_port|type=="number") and
             (.health_path|type=="string") and (.health_path|startswith("/")) and
             (.db_name|type=="string") and (.db_user|type=="string") and
             (.task_cpu|type=="number") and (.task_memory|type=="number") and
             (.desired_count|type=="number") and (.desired_count >= 1) and
             (.checks.lint|type=="boolean") and (.checks.test|type=="boolean") and
             (.containers.web.port|type=="number") and
             (.containers.api.port|type=="number") and
             (.env|type=="object")
           )] | length == $n' "$file" >/dev/null \
    || fail "a service is missing a required field or has the wrong type (see the jq filter in this script)"

  # --- migrations + connection pool -------------------------------------
  jq -e '(.services|length) as $n
         | [.services[] | select(
             (.migrations.enabled|type=="boolean") and
             (.migrations.command|type=="array") and (.migrations.command|length > 0) and
             (.migrations.timeout_seconds|type=="number") and
             (.db.pool_size|type=="number") and (.db.max_overflow|type=="number") and
             (.db.pool_recycle_seconds|type=="number") and
             (.db.pool_timeout_seconds|type=="number")
           )] | length == $n' "$file" >/dev/null \
    || fail "a service is missing its migrations{} or db{} block, or a field has the wrong type"

  # THE CONNECTION BUDGET. db.t3.micro allows roughly 87 connections
  # (LEAST({DBInstanceClassMemory/ 9531392}, 5000) on 1GB).
  # AUTOSCALING_MAX multiplies the peak: a service that scales to N tasks holds
  # N times the connections, and the rollout window still doubles that. Pass the
  # same value as terraform's autoscaling_max_capacity, or the budget is checked
  # against a task count the service can exceed on its own.
  local budget peak reserved=10 scale="${AUTOSCALING_MAX:-1}"
  budget="${DB_MAX_CONNECTIONS:-87}"
  peak="$(jq -r --argjson scale "$scale" '
    ([.services[] | (.db.pool_size + .db.max_overflow) * (.desired_count * $scale) * 2] | add)
    + ([.services[] | select(.migrations.enabled)] | length)
  ' "$file")"
  if [ "$peak" -gt $((budget - reserved)) ]; then
    fail "connection budget: peak ${peak} against ~${budget} on db.t3.micro (${reserved} reserved for superuser and maintenance).
       Peak = (pool_size + max_overflow) x (desired_count x ${scale}) x 2 for the 200% rollout window, plus one per migration task.
       Lower pool_size, lower autoscaling_max_capacity, or move to a larger instance class."
  fi

  local dupes
  dupes="$(jq -r '[.services[].alb_listener_port] | group_by(.) | map(select(length>1)) | length' "$file")"
  [ "$dupes" = "0" ] || fail "two services share an alb_listener_port — the second listener would fail to create"

  dupes="$(jq -r '[.services[].key] | group_by(.) | map(select(length>1)) | length' "$file")"
  [ "$dupes" = "0" ] || fail "duplicate service key — Terraform for_each would collapse them into one"

  dupes="$(jq -r '[.services[].db_name] | group_by(.) | map(select(length>1)) | length' "$file")"
  [ "$dupes" = "0" ] || fail "two services share a db_name — they would share a schema on one RDS instance"

  # The API port must never be an ALB listener port. Nothing outside the task
  # can reach uvicorn by design (§4.2), and publishing that port would be a
  # silent hole in exactly the property the architecture claims.
  jq -e '[.services[] | select(.alb_listener_port == .containers.api.port)] | length == 0' "$file" >/dev/null \
    || fail "a service publishes its API container port on the ALB — the API port is meant to be unreachable from outside the task"

  # Fargate cpu/memory pairings.
  local key cpu mem
  while IFS=$'\t' read -r key cpu mem; do
    valid_fargate_combo "$cpu" "$mem" \
      || fail "${key}: task_cpu=${cpu} with task_memory=${mem} is not a valid Fargate combination"
  done < <(jq -r '.services[] | [.key, .task_cpu, .task_memory] | @tsv' "$file")

  echo "services.json OK — $(jq -r '.services | length' "$file") service(s): $(jq -r '[.services[].key] | join(", ")' "$file")"
}

# --- Self-test --------------------------------------------------------------
# Trap 25: negative-test your validator. A validator that accepts everything
# passes CI forever and catches nothing.
self_test() {
  local tmp status failures=0
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  check_rejects() {
    local name="$1" filter="$2"
    jq "$filter" "${REPO_ROOT}/services/services.json" > "${tmp}/bad.json"
    # A SUBSHELL, not a plain call. `fail` ends with `exit 1`, and an exit
    # inside a function ends the whole script — `set +e` does not save you.
    # This is the same class of mistake the validator exists to catch.
    set +e
    ( validate "${tmp}/bad.json" ) >/dev/null 2>&1
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
      echo "  FAIL  accepted bad input: ${name}"
      failures=$((failures + 1))
    else
      echo "  ok    rejected: ${name}"
    fi
  }

  echo "Self-test — the validator must REJECT each of these:"
  check_rejects "missing db_user"            'del(.services[0].db_user)'
  check_rejects "missing checks.lint"        'del(.services[0].checks.lint)'
  check_rejects "duplicate listener port"    '.services[1].alb_listener_port = .services[0].alb_listener_port'
  check_rejects "duplicate service key"      '.services[1].key = .services[0].key'
  check_rejects "duplicate db_name"          '.services[1].db_name = .services[0].db_name'
  check_rejects "health_path not absolute"   '.services[0].health_path = "api/health"'
  check_rejects "desired_count of 0"         '.services[0].desired_count = 0'
  check_rejects "invalid Fargate cpu/memory" '.services[0].task_memory = 768'
  check_rejects "API port exposed on ALB"    '.services[0].alb_listener_port = .services[0].containers.api.port'
  check_rejects "uppercase service key"      '.services[0].key = "FinSight"'
  check_rejects "empty services array"       '.services = []'
  check_rejects "missing migrations block"   'del(.services[0].migrations)'
  check_rejects "missing db pool block"      'del(.services[0].db)'
  check_rejects "empty migration command"    '.services[0].migrations.command = []'
  check_rejects "pool exceeds db.t3.micro"   '.services[0].db.pool_size = 40'

  # The same manifest that passes at one task must FAIL once autoscaling can
  # run four of them. This is the whole point of threading the scale factor in.
  echo "  ...and the budget must track autoscaling:"
  set +e
  ( AUTOSCALING_MAX=4 validate "${REPO_ROOT}/services/services.json" ) >/dev/null 2>&1
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    echo "  FAIL  accepted a 4x scale-out that exceeds the connection budget"
    failures=$((failures + 1))
  else
    echo "  ok    rejected: autoscaling_max_capacity of 4"
  fi

  echo
  echo "And it must ACCEPT the real manifest:"
  if ( validate "${REPO_ROOT}/services/services.json" ) >/dev/null 2>&1; then
    echo "  ok    accepted services/services.json"
  else
    echo "  FAIL  rejected the real manifest"
    failures=$((failures + 1))
  fi

  echo
  if [ "$failures" -eq 0 ]; then
    echo "Self-test passed."
    return 0
  fi
  echo "Self-test FAILED: ${failures} case(s)." >&2
  return 1
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
else
  validate "$MANIFEST"
fi
