#!/usr/bin/env bash
# Measure the image size the optimisation actually bought.
set -euo pipefail

SERVICE_REPO="${1:?usage: measure-image-size.sh <path-to-service-repo> <service-key>}"
SERVICE_KEY="${2:?usage: measure-image-size.sh <path-to-service-repo> <service-key>}"
PIPELINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVICE_REPO="$(cd "$SERVICE_REPO" && pwd)"

command -v docker >/dev/null || { echo "docker not running" >&2; exit 1; }

# --- Two different numbers, and they are both "the image size" -------------
# COMPRESSED is what crosses the network on `docker pull` and what ECR bills for
# storage.

uses_containerd_store() {
  docker info --format '{{.DriverStatus}}' 2>/dev/null | grep -q 'io.containerd.snapshotter'
}

# Compressed: the sum of the layer blobs, straight from the manifest.
compressed_mb() {
  docker image inspect "$1" --format '{{.Size}}' 2>/dev/null \
    | awk '{printf "%.0f", $1/1048576}'
}

# Uncompressed: `docker images` prints a human string (342MB, 1.2GB, 976kB).
# Parsing it is unlovely, but it is the only number the CLI exposes for the
# on-disk size under the containerd store.
uncompressed_mb() {
  docker images --format '{{.Size}}' --filter "reference=$1" 2>/dev/null \
    | head -1 \
    | awk '{
        v = $0
        sub(/[A-Za-z]+$/, "", v)
        unit = $0
        sub(/^[0-9.]+/, "", unit)
        if (unit ~ /^GB/)      printf "%.0f", v * 1024
        else if (unit ~ /^MB/) printf "%.0f", v
        else if (unit ~ /^kB/ || unit ~ /^KB/) printf "%.0f", v / 1024
        else if (unit ~ /^B/)  printf "%.0f", v / 1048576
        else printf "0"
      }'
}

layers() { docker history --no-trunc --format '{{.Size}}' "$1" 2>/dev/null | wc -l | tr -d ' '; }

echo "==> Building BASELINE (the service repo's own backend/Dockerfile)"
docker build -q -t "measure/${SERVICE_KEY}-api:baseline" \
  -f "${SERVICE_REPO}/backend/Dockerfile" "${SERVICE_REPO}/backend" >/dev/null

echo "==> Building OPTIMISED (docker/Dockerfile.api, multi-stage)"
cp "${PIPELINE_DIR}/docker/dockerignore.service" "${SERVICE_REPO}/.dockerignore"
cp "${PIPELINE_DIR}/docker/nginx.ecs.conf" "${SERVICE_REPO}/nginx.ecs.conf"
docker build -q -t "measure/${SERVICE_KEY}-api:optimised" \
  -f "${PIPELINE_DIR}/docker/Dockerfile.api" \
  --build-arg "GIT_SHA=measure" --build-arg "SERVICE_NAME=${SERVICE_KEY}" \
  "${SERVICE_REPO}" >/dev/null

echo "==> Building frontend"
docker build -q -t "measure/${SERVICE_KEY}-web:baseline" \
  -f "${SERVICE_REPO}/frontend/Dockerfile" "${SERVICE_REPO}/frontend" >/dev/null
docker build -q -t "measure/${SERVICE_KEY}-web:optimised" \
  -f "${PIPELINE_DIR}/docker/Dockerfile.frontend" \
  --build-arg "GIT_SHA=measure" "${SERVICE_REPO}" >/dev/null

api_before=$(uncompressed_mb "measure/${SERVICE_KEY}-api:baseline")
api_after=$(uncompressed_mb "measure/${SERVICE_KEY}-api:optimised")
web_before=$(uncompressed_mb "measure/${SERVICE_KEY}-web:baseline")
web_after=$(uncompressed_mb "measure/${SERVICE_KEY}-web:optimised")

api_before_c=$(compressed_mb "measure/${SERVICE_KEY}-api:baseline")
api_after_c=$(compressed_mb "measure/${SERVICE_KEY}-api:optimised")
web_before_c=$(compressed_mb "measure/${SERVICE_KEY}-web:baseline")
web_after_c=$(compressed_mb "measure/${SERVICE_KEY}-web:optimised")

if uses_containerd_store; then
  STORE="containerd snapshotter"
else
  STORE="classic image store"
fi

pct() { awk -v b="$1" -v a="$2" 'BEGIN{ if (b==0) print "n/a"; else printf "%.1f%%", (b-a)*100/b }'; }

cat <<EOF

  service            ${SERVICE_KEY}
  image store        ${STORE}

  ON DISK (uncompressed — what the layer cache holds)
  api  baseline      ${api_before} MB   (${SERVICE_REPO}/backend/Dockerfile, single stage)
  api  optimised     ${api_after} MB   (docker/Dockerfile.api, multi-stage)
  api  reduction     $(pct "$api_before" "$api_after")
  web  baseline      ${web_before} MB
  web  optimised     ${web_after} MB
  web  reduction     $(pct "$web_before" "$web_after")

  ON THE WIRE (compressed — what docker pull transfers, what ECR stores)
  api  baseline      ${api_before_c} MB
  api  optimised     ${api_after_c} MB
  api  reduction     $(pct "$api_before_c" "$api_after_c")
  web  baseline      ${web_before_c} MB
  web  optimised     ${web_after_c} MB
  web  reduction     $(pct "$web_before_c" "$web_after_c")

  Quote the compressed number for pull time and registry cost, the
  uncompressed one for disk. Say which one you mean.

EOF

report="${PIPELINE_DIR}/docs/image-size-report.md"
{
  echo "## ${SERVICE_KEY} — measured $(date -u +%Y-%m-%d)"
  echo
  echo "Docker image store: \`${STORE}\`. Both numbers below are real and they"
  echo "measure different things — see the note at the top of this file."
  echo
  echo "| image | | baseline | optimised | reduction |"
  echo "|---|---|---|---|---|"
  echo "| api | on disk | ${api_before} MB | ${api_after} MB | $(pct "$api_before" "$api_after") |"
  echo "| api | compressed | ${api_before_c} MB | ${api_after_c} MB | $(pct "$api_before_c" "$api_after_c") |"
  echo "| web | on disk | ${web_before} MB | ${web_after} MB | $(pct "$web_before" "$web_after") |"
  echo "| web | compressed | ${web_before_c} MB | ${web_after_c} MB | $(pct "$web_before_c" "$web_after_c") |"
  echo
  echo "Layer count (api): $(layers "measure/${SERVICE_KEY}-api:baseline") -> $(layers "measure/${SERVICE_KEY}-api:optimised")"
  echo
} >> "$report"
echo "Appended to ${report}"
echo
echo "Put the REAL numbers on the resume. Not these ones unless you ran this."
