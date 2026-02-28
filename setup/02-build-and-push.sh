#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# setup/02-build-and-push.sh
#
# Builds the custom AlloyDB Omni image (with gcloud CLI + WAL entrypoint)
# and pushes it to Artifact Registry.
#
# The Langfuse web and worker images are official images pulled directly from
# Docker Hub in the service.yaml — no local build needed for those.
#
# Run: bash setup/02-build-and-push.sh
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [ ! -f "${ROOT_DIR}/.env" ]; then
  echo "ERROR: .env not found."
  exit 1
fi
# shellcheck disable=SC1091
source "${ROOT_DIR}/.env"

: "${PROJECT_ID:?}"
: "${REGION:?}"
: "${ARTIFACT_REGISTRY_REPO:?}"

IMAGE_BASE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REGISTRY_REPO}"
ALLOYDB_IMAGE="${IMAGE_BASE}/alloydb-omni:latest"
CLICKHOUSE_IMAGE="${IMAGE_BASE}/clickhouse:latest"

echo "==> Configuring Docker auth for Artifact Registry..."
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet

echo "==> Building AlloyDB Omni image: ${ALLOYDB_IMAGE}"
docker build \
  --platform linux/amd64 \
  --tag "${ALLOYDB_IMAGE}" \
  "${ROOT_DIR}/alloydb-omni"

echo "==> Building ClickHouse image: ${CLICKHOUSE_IMAGE}"
docker build \
  --platform linux/amd64 \
  --tag "${CLICKHOUSE_IMAGE}" \
  "${ROOT_DIR}/clickhouse"

echo "==> Pushing images..."
docker push "${ALLOYDB_IMAGE}"
docker push "${CLICKHOUSE_IMAGE}"

echo ""
echo "✓ Images pushed:"
echo "  ${ALLOYDB_IMAGE}"
echo "  ${CLICKHOUSE_IMAGE}"
echo "  Next step: bash setup/03-deploy.sh"
