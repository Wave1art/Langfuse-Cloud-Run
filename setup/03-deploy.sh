#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# setup/03-deploy.sh
#
# Deploys (or updates) the Langfuse multi-container Cloud Run service by:
#   1. Substituting template variables in cloud-run/service.yaml
#   2. Running `gcloud run services replace` to apply the spec
#   3. Printing the service URL
#
# On the very first deploy, NEXTAUTH_URL will use a placeholder.
# After the URL is known, re-run this script — it will update automatically.
#
# Run: bash setup/03-deploy.sh
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
: "${SERVICE_NAME:?}"
: "${ARTIFACT_REGISTRY_REPO:?}"
: "${GCS_WAL_BUCKET:?}"
: "${SERVICE_ACCOUNT_NAME:?}"
: "${POSTGRES_USER:?}"
: "${POSTGRES_DB:?}"

# Derive SERVICE_URL from an existing deployment (empty on first run)
SERVICE_URL="${SERVICE_URL:-}"
if [ -z "${SERVICE_URL}" ]; then
  SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format="value(status.url)" 2>/dev/null \
    | sed 's|https://||' || echo "PLACEHOLDER.run.app")
fi

export PROJECT_ID REGION SERVICE_NAME ARTIFACT_REGISTRY_REPO \
       GCS_WAL_BUCKET SERVICE_ACCOUNT_NAME POSTGRES_USER POSTGRES_DB SERVICE_URL

RENDERED="${ROOT_DIR}/cloud-run/.service-rendered.yaml"

echo "==> Rendering service.yaml for project=${PROJECT_ID} region=${REGION}..."
envsubst < "${ROOT_DIR}/cloud-run/service.yaml" > "${RENDERED}"

echo "==> Deploying Cloud Run service: ${SERVICE_NAME}"
gcloud run services replace "${RENDERED}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}"

# Retrieve and display the final service URL
FINAL_URL=$(gcloud run services describe "${SERVICE_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(status.url)")

echo ""
echo "✓ Deployed: ${FINAL_URL}"
echo ""
echo "  If this is the first deploy, update NEXTAUTH_URL:"
echo "  1. Add SERVICE_URL=$(echo "${FINAL_URL}" | sed 's|https://||') to .env"
echo "  2. Re-run: bash setup/03-deploy.sh"
echo ""
echo "  Langfuse UI: ${FINAL_URL}"

# Allow all traffic (make the service publicly accessible)
gcloud run services add-iam-policy-binding "${SERVICE_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --member="allUsers" \
  --role="roles/run.invoker" 2>/dev/null || true
