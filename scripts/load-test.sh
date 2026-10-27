#!/usr/bin/env bash
# Run the k6 load profile against a live URL and write the result into
# docs/load-test-report.md.
set -euo pipefail

cd "$(dirname "$0")/.."

BASE_URL="${1:?Usage: ./scripts/load-test.sh <base-url> [ramp|stress|soak]}"
PROFILE="${2:-ramp}"

case "$PROFILE" in
  ramp|stress|soak) ;;
  *) echo "Unknown profile '${PROFILE}'. Use ramp, stress or soak." >&2; exit 1 ;;
esac

if ! command -v k6 >/dev/null 2>&1; then
  cat >&2 <<'EOF'
k6 is not installed.

  macOS:  brew install k6
  Linux:  https://grafana.com/docs/k6/latest/set-up/install-k6/

Or run it in a container without installing anything:

  docker run --rm -i -v "$PWD/load:/load" grafana/k6 run \
    -e BASE_URL=<url> /load/smoke.js
EOF
  exit 1
fi

# Fail fast rather than spending two minutes discovering the URL is wrong.
echo "==> Checking ${BASE_URL}/api/health is reachable before starting"
if ! curl -fsS --max-time 10 "${BASE_URL}/api/health" >/dev/null; then
  echo "ERROR: ${BASE_URL}/api/health did not answer. Is the stack up?" >&2
  echo "       make outputs   # shows the live URLs" >&2
  exit 1
fi

echo "==> Running the '${PROFILE}' profile against ${BASE_URL}"
set +e
k6 run -e "BASE_URL=${BASE_URL}" -e "PROFILE=${PROFILE}" load/smoke.js
K6_STATUS=$?
set -e

REPORT="docs/load-test-report.md"
if [ ! -f "$REPORT" ]; then
  cat > "$REPORT" <<'EOF'
# Load test results

Measured, not estimated. Each row is a real `scripts/load-test.sh` run against
a live deployment — if this table is empty, the load test has not been run and
the honest answer to "how does it perform under load" is still "I do not know".

The architecture being measured: one Fargate task (512 CPU units, 1GB) running
nginx and uvicorn in one task definition, behind one ALB, against a
db.t3.micro. `desired_count = 1`, no autoscaling. These numbers describe one
task. They say nothing about how the service scales, because it does not.

| date | profile | rps | error rate | p50 | p95 | p99 | notes |
|---|---|---|---|---|---|---|---|
EOF
fi

if [ -f load-results.json ] && command -v jq >/dev/null 2>&1; then
  ROW="$(jq -r --arg d "$(date -u +%Y-%m-%d)" --arg p "$PROFILE" --arg s "$K6_STATUS" '
    .metrics as $m |
    "| \($d) | \($p) | \($m.http_reqs.values.rate | . * 10 | round / 10) " +
    "| \(($m.http_req_failed.values.rate * 100) | . * 100 | round / 100)% " +
    "| \($m.http_req_duration.values.med | round)ms " +
    "| \($m.http_req_duration.values["p(95)"] | round)ms " +
    "| \($m.http_req_duration.values["p(99)"] | round)ms " +
    "| \(if $s == "0" then "thresholds met" else "THRESHOLDS BREACHED" end) |"
  ' load-results.json)"
  printf '%s\n' "$ROW" >> "$REPORT"
  rm -f load-results.json
  echo
  echo "Appended to ${REPORT}:"
  printf '%s\n' "$ROW"
fi

if [ "$K6_STATUS" -ne 0 ]; then
  echo
  echo "k6 exited ${K6_STATUS} — a threshold was breached." >&2
  echo "That is a result, not a script failure. See ${REPORT}." >&2
fi
exit "$K6_STATUS"
