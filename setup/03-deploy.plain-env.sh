#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# setup/03-deploy.plain-env.sh
#
# VARIANT — no Secret Manager.
# Renders cloud-run/service.plain-env.yaml via envsubst (all variables including
# secrets come from .env) then deploys with `gcloud run services replace`.
#
# The rendered YAML is written to a mktemp file and deleted on exit — it is
# never persisted to disk beyond the duration of this script.
#
# Run: bash setup/03-deploy.plain-env.sh
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "ERROR: .env not found."
  exit 1
fi
# shellcheck disable=SC1091
source "${ENV_FILE}"

# ── Validate required variables ───────────────────────────────────────────────
required_vars=(
  PROJECT_ID REGION SERVICE_NAME ARTIFACT_REGISTRY_REPO
  GCS_WAL_BUCKET SERVICE_ACCOUNT_NAME
  POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD DATABASE_URL
  NEXTAUTH_SECRET SALT ENCRYPTION_KEY
  GCS_HMAC_ACCESS_KEY GCS_HMAC_SECRET_KEY
)
missing=()
for var in "${required_vars[@]}"; do
  [ -z "${!var:-}" ] && missing+=("${var}")
done
if [ ${#missing[@]} -gt 0 ]; then
  echo "ERROR: The following variables are not set in .env:"
  printf '  %s\n' "${missing[@]}"
  echo ""
  echo "  Run setup/01-gcp-resources.plain-env.sh first, then fill in"
  echo "  any remaining values in .env."
  exit 1
fi

# ── Resolve SERVICE_URL ───────────────────────────────────────────────────────
# On first deploy we don't know the URL yet — use a placeholder and warn.
SERVICE_URL="${SERVICE_URL:-}"
if [ -z "${SERVICE_URL}" ]; then
  SERVICE_URL=$(gcloud run services describe "${SERVICE_NAME}" \
    --region="${REGION}" \
    --project="${PROJECT_ID}" \
    --format="value(status.url)" 2>/dev/null \
    | sed 's|https://||' || echo "")
fi
if [ -z "${SERVICE_URL}" ]; then
  SERVICE_URL="PLACEHOLDER.run.app"
  echo "  NOTE: SERVICE_URL unknown (first deploy). Using placeholder."
  echo "        After this deploy, add SERVICE_URL=<printed URL> to .env"
  echo "        and re-run this script."
fi

export PROJECT_ID REGION SERVICE_NAME ARTIFACT_REGISTRY_REPO \
       GCS_WAL_BUCKET SERVICE_ACCOUNT_NAME SERVICE_URL \
       POSTGRES_USER POSTGRES_DB POSTGRES_PASSWORD DATABASE_URL \
       NEXTAUTH_SECRET SALT ENCRYPTION_KEY \
       GCS_HMAC_ACCESS_KEY GCS_HMAC_SECRET_KEY

# ── Render service.yaml to a temporary file ───────────────────────────────────
# Use mktemp so the file has an unpredictable name and lives in /tmp.
# The EXIT trap guarantees it is deleted even if the script fails.
RENDERED=$(mktemp /tmp/langfuse-service-XXXXXX.yaml)
trap 'rm -f "${RENDERED}"' EXIT

echo "==> Rendering service.plain-env.yaml → ${RENDERED} (ephemeral)"
envsubst < "${ROOT_DIR}/cloud-run/service.plain-env.yaml" > "${RENDERED}"

# Restrict permissions so only the current user can read the rendered file
chmod 600 "${RENDERED}"

echo "==> Deploying Cloud Run service: ${SERVICE_NAME}"
gcloud run services replace "${RENDERED}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}"

# Rendered file is deleted here by the EXIT trap.

# ── Retrieve and display the service URL ─────────────────────────────────────
FINAL_URL=$(gcloud run services describe "${SERVICE_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="value(status.url)")

echo ""
echo "✓ Deployed: ${FINAL_URL}"

# Make the service publicly accessible (remove to restrict access)
gcloud run services add-iam-policy-binding "${SERVICE_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --member="allUsers" \
  --role="roles/run.invoker" 2>/dev/null || true

if [ "${SERVICE_URL}" = "PLACEHOLDER.run.app" ]; then
  echo ""
  echo "  ACTION REQUIRED — update .env and redeploy:"
  echo "  SERVICE_URL=$(echo "${FINAL_URL}" | sed 's|https://||')"
  echo ""
  echo "  Then run:  bash setup/03-deploy.plain-env.sh"
fi
