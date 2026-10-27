#!/usr/bin/env bash
# Run a service locally with the SAME images the pipeline ships.
#   ./scripts/local-up.sh finsight
set -euo pipefail

cd "$(dirname "$0")/.."
PIPELINE_DIR="$(pwd)"
KEY="${1:-finsight}"
WORKSPACE="${WORKSPACE:-$(dirname "$PIPELINE_DIR")}"

svc="$(jq -c --arg k "$KEY" '.services[] | select(.key==$k)' services/services.json)"
[ -n "$svc" ] || { echo "Unknown service '${KEY}'. Known: $(jq -r '[.services[].key]|join(", ")' services/services.json)" >&2; exit 1; }

repo=$(echo "$svc" | jq -r .repo)
dir="${WORKSPACE}/$(basename "$repo")"
[ -d "$dir" ] || { echo "Expected the service repo at ${dir}. Clone it, or set WORKSPACE." >&2; exit 1; }

# The build context is the service repo, so the ignore file has to live there.
cp "${PIPELINE_DIR}/docker/dockerignore.service" "${dir}/.dockerignore"
cp "${PIPELINE_DIR}/docker/nginx.ecs.conf" "${dir}/nginx.ecs.conf"

DB_NAME="$(echo "$svc" | jq -r .db_name)"
DB_USER="$(echo "$svc" | jq -r .db_user)"
GIT_SHA="$(git -C "$dir" rev-parse --short=8 HEAD 2>/dev/null || echo local)"
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

export SERVICE_REPO="$dir"
export AUTODEPLOYX_DIR="$PIPELINE_DIR"
export SERVICE_NAME="$KEY"
export DB_NAME DB_USER GIT_SHA BUILD_TIME

echo "Starting ${KEY} @ ${GIT_SHA} from ${dir}"
docker compose -f docker/docker-compose.yml up --build "$@"

echo
echo "  app:    http://localhost:8080"
echo "  api:    http://localhost:8000/docs"
echo "  health: http://localhost:8080/api/health"
