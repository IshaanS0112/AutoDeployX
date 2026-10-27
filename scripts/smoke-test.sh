#!/usr/bin/env bash
# Post-deploy verification against the LIVE URL, from outside the VPC.
set -euo pipefail

SERVICE_URL="${SERVICE_URL:?SERVICE_URL is required}"
HEALTH_PATH="${HEALTH_PATH:-/api/health}"
EXPECTED_SHA="${EXPECTED_SHA:-}"
ATTEMPTS="${ATTEMPTS:-20}"
SLEEP_SECONDS="${SLEEP_SECONDS:-6}"

fail() { echo "SMOKE TEST FAILED: $*" >&2; exit 1; }

echo "Smoke testing ${SERVICE_URL}"

# --- 1. Health endpoint, with retries --------------------------------------
# Retried because ALB target registration and DNS propagation both take a few
# seconds after ECS reports the rollout complete.
body=""
for i in $(seq 1 "$ATTEMPTS"); do
  if body="$(curl -fsS --max-time 10 "${SERVICE_URL}${HEALTH_PATH}" 2>/dev/null)"; then
    echo "health OK on attempt ${i}"
    break
  fi
  echo "  attempt ${i}/${ATTEMPTS} — not ready yet"
  sleep "$SLEEP_SECONDS"
  body=""
done
[ -n "$body" ] || fail "${SERVICE_URL}${HEALTH_PATH} never returned 200 after $((ATTEMPTS * SLEEP_SECONDS))s"

echo "health response: ${body}"

# --- 2. The health check must be a REAL check ------------------------------
# The endpoint reports its database connectivity. A deploy where the app is up
# but cannot reach RDS is a failed deploy, and this is where that surfaces.
status="$(echo "$body" | jq -r '.status // empty')"
[ "$status" = "healthy" ] || [ "$status" = "ok" ] || fail "status is '${status}', expected healthy"

db="$(echo "$body" | jq -r '.checks.database // "absent"')"
case "$db" in
  ok)      echo "database: reachable" ;;
  absent)  echo "WARNING: /health does not report a database check."
           echo "         Apply patches/ to the service repo — see patches/README.md." ;;
  *)       fail "database check reported '${db}'" ;;
esac

# --- 3. Is the deployed commit the one we think it is? ---------------------
if [ -n "$EXPECTED_SHA" ]; then
  deployed="$(echo "$body" | jq -r '.commit // empty')"
  if [ -z "$deployed" ] || [ "$deployed" = "unknown" ]; then
    echo "WARNING: /health does not report a commit SHA — cannot verify what is deployed."
    echo "         This is the single most useful field on a health endpoint."
  elif [ "$deployed" != "$EXPECTED_SHA" ]; then
    fail "live service reports commit '${deployed}', expected '${EXPECTED_SHA}'.
       Traffic is being served by a different revision than the one just deployed."
  else
    echo "commit verified: ${deployed}"
  fi
fi

# --- 4. The frontend is actually served -------------------------------------
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${SERVICE_URL}/")"
[ "$code" = "200" ] || fail "GET / returned ${code}, expected 200 (nginx is not serving the SPA)"
echo "frontend: 200"

# --- 5. SPA fallback works --------------------------------------------------
# A deep link must return the app shell, not a 404. This catches a broken
# try_files, which only shows up when someone refreshes on a sub-route.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${SERVICE_URL}/some/client/route")"
[ "$code" = "200" ] || fail "deep link returned ${code}, expected 200 (nginx try_files fallback broken)"
echo "SPA routing: 200"

echo "SMOKE TEST PASSED — ${SERVICE_URL}"
