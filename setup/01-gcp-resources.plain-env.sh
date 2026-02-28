#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# setup/01-gcp-resources.plain-env.sh
#
# VARIANT — no Secret Manager.
# Creates GCP infrastructure only (bucket, Artifact Registry, service account,
# IAM bindings).  Secrets are kept in .env and injected at deploy time via
# envsubst — they are never stored in Secret Manager.
#
# Also creates the GCS HMAC key needed for Langfuse's S3-compatible blob store
# and writes the resulting key/secret directly into your .env file.
#
# Run: bash setup/01-gcp-resources.plain-env.sh
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"

if [ ! -f "${ENV_FILE}" ]; then
  echo "ERROR: .env not found. Copy .env.example to .env and fill in values."
  exit 1
fi
# shellcheck disable=SC1091
source "${ENV_FILE}"

: "${PROJECT_ID:?}"
: "${REGION:?}"
: "${GCS_WAL_BUCKET:?}"
: "${SERVICE_ACCOUNT_NAME:?}"
: "${ARTIFACT_REGISTRY_REPO:?}"

echo "==> Setting project to ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}"

# ── Enable required APIs ───────────────────────────────────────────────────────
echo "==> Enabling required APIs..."
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  storage.googleapis.com \
  iam.googleapis.com \
  --project="${PROJECT_ID}"

# ── Artifact Registry ─────────────────────────────────────────────────────────
echo "==> Creating Artifact Registry repo: ${ARTIFACT_REGISTRY_REPO}"
gcloud artifacts repositories create "${ARTIFACT_REGISTRY_REPO}" \
  --repository-format=docker \
  --location="${REGION}" \
  --description="Langfuse Cloud Run images" \
  --project="${PROJECT_ID}" 2>/dev/null || echo "    (already exists)"

# ── GCS bucket ────────────────────────────────────────────────────────────────
echo "==> Creating GCS bucket: gs://${GCS_WAL_BUCKET}"
gcloud storage buckets create "gs://${GCS_WAL_BUCKET}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --uniform-bucket-level-access 2>/dev/null || echo "    (already exists)"

gcloud storage buckets update "gs://${GCS_WAL_BUCKET}" --versioning

# Delete WAL segments older than 14 days; base backups are kept indefinitely
gcloud storage buckets update "gs://${GCS_WAL_BUCKET}" \
  --lifecycle-file=- <<'EOF'
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {"age": 14, "matchesPrefix": ["wal/"]}
    }
  ]
}
EOF

# ── Service account ───────────────────────────────────────────────────────────
SA_EMAIL="${SERVICE_ACCOUNT_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
echo "==> Creating service account: ${SA_EMAIL}"
gcloud iam service-accounts create "${SERVICE_ACCOUNT_NAME}" \
  --display-name="Langfuse Cloud Run SA" \
  --project="${PROJECT_ID}" 2>/dev/null || echo "    (already exists)"

echo "==> Granting Storage Object Admin on gs://${GCS_WAL_BUCKET}"
gcloud storage buckets add-iam-policy-binding "gs://${GCS_WAL_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin"

# ── HMAC key for GCS S3-compatible API ────────────────────────────────────────
# The secret is shown exactly once — we capture and write it to .env directly.
echo "==> Creating GCS HMAC key for service account ${SA_EMAIL}..."

HMAC_JSON=$(gcloud storage hmac create "${SA_EMAIL}" \
  --project="${PROJECT_ID}" --format=json 2>/dev/null || echo "")

if [ -z "${HMAC_JSON}" ]; then
  echo ""
  echo "  WARNING: Could not create HMAC key (it may already exist)."
  echo "  List existing keys with:"
  echo "    gcloud storage hmac list --service-account=${SA_EMAIL} --project=${PROJECT_ID}"
  echo "  If you need to rotate, delete the old key first, then re-run this script."
else
  HMAC_ACCESS=$(echo "${HMAC_JSON}" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['metadata']['accessId'])")
  HMAC_SECRET=$(echo "${HMAC_JSON}" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['secret'])")

  # Write into .env (append or update)
  update_env_var() {
    local key="$1" val="$2"
    if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
      # Replace existing line (cross-platform sed)
      sed -i.bak "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}" && rm -f "${ENV_FILE}.bak"
    else
      echo "${key}=${val}" >> "${ENV_FILE}"
    fi
  }

  update_env_var "GCS_HMAC_ACCESS_KEY" "${HMAC_ACCESS}"
  update_env_var "GCS_HMAC_SECRET_KEY" "${HMAC_SECRET}"

  echo "    HMAC key written to .env (GCS_HMAC_ACCESS_KEY / GCS_HMAC_SECRET_KEY)"
fi

# Compute and persist DATABASE_URL so deploy scripts can pick it up
POSTGRES_USER="${POSTGRES_USER:-langfuse}"
POSTGRES_DB="${POSTGRES_DB:-langfuse}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD must be set in .env}"
DB_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:5432/${POSTGRES_DB}"

update_env_var() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}" && rm -f "${ENV_FILE}.bak"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}
update_env_var "DATABASE_URL" "${DB_URL}"
echo "    DATABASE_URL written to .env"

echo ""
echo "✓ GCP resources ready (no Secret Manager used)."
echo "  Next step: bash setup/02-build-and-push.sh"
echo "  Then:      bash setup/03-deploy.plain-env.sh"
