#!/usr/bin/env bash
# Build and push the FIRST images, locally, so the services can start.
set -euo pipefail

cd "$(dirname "$0")/.."
PIPELINE_DIR="$(pwd)"
AWS_REGION="${AWS_REGION:-ap-south-1}"
PROJECT="${PROJECT:-autodeployx}"
# Where the service repos are checked out. Defaults to siblings of this repo.
WORKSPACE="${WORKSPACE:-$(dirname "$PIPELINE_DIR")}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "Logging in to ${REGISTRY}"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY"

jq -c '.services[]' services/services.json | while read -r svc; do
  key=$(echo "$svc" | jq -r .key)
  repo=$(echo "$svc" | jq -r .repo)
  dir="${WORKSPACE}/$(basename "$repo")"

  if [ ! -d "$dir" ]; then
    echo "Cloning ${repo} into ${dir}"
    git clone --depth 1 "https://github.com/${repo}.git" "$dir"
  fi

  sha="$(git -C "$dir" rev-parse --short=8 HEAD)"
  echo
  echo "=== ${key} @ ${sha} (from ${dir}) ==="

  cp "${PIPELINE_DIR}/docker/dockerignore.service" "${dir}/.dockerignore"
  cp "${PIPELINE_DIR}/docker/nginx.ecs.conf" "${dir}/nginx.ecs.conf"

  docker build \
    -f "${PIPELINE_DIR}/docker/Dockerfile.api" \
    --build-arg "GIT_SHA=${sha}" \
    --build-arg "BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --build-arg "SERVICE_NAME=${key}" \
    -t "${REGISTRY}/${PROJECT}/${key}-api:${sha}" "$dir"

  docker build \
    -f "${PIPELINE_DIR}/docker/Dockerfile.frontend" \
    --build-arg "GIT_SHA=${sha}" \
    -t "${REGISTRY}/${PROJECT}/${key}-web:${sha}" "$dir"

  docker push "${REGISTRY}/${PROJECT}/${key}-api:${sha}"
  docker push "${REGISTRY}/${PROJECT}/${key}-web:${sha}"

  echo "Deploying ${key} @ ${sha}"
  SERVICE_KEY="$key" IMAGE_TAG="$sha" \
    CLUSTER="$(terraform -chdir=terraform output -raw ecs_cluster_name)" \
    AWS_REGION="$AWS_REGION" ./scripts/deploy.sh
done

echo
echo "Seeded. Live URLs:"
terraform -chdir=terraform output -json service_urls | jq -r 'to_entries[] | "  \(.key): \(.value)"'
