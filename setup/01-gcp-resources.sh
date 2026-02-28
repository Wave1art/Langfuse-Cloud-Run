#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# setup/01-gcp-resources.sh
#
# One-time setup: creates all GCP infrastructure needed before the first deploy.
# Run from the repo root: bash setup/01-gcp-resources.sh
#
# Prerequisites:
#   • gcloud CLI installed and authenticated (`gcloud auth login`)
#   • .env file present (copy from .env.example and fill in)
#   • Billing enabled on the project
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Load .env
if [ ! -f "${ROOT_DIR}/.env" ]; then
  echo "ERROR: .env not found. Copy .env.example to .env and fill in values."
  exit 1
fi
# shellcheck disable=SC1091
source "${ROOT_DIR}/.env"

: "${PROJECT_ID:?}"
: "${REGION:?}"
: "${GCS_WAL_BUCKET:?}"
: "${SERVICE_ACCOUNT_NAME:?}"
: "${ARTIFACT_REGISTRY_REPO:?}"
: "${NEXTAUTH_SECRET:?}"
: "${SALT:?}"
: "${ENCRYPTION_KEY:?}"
: "${POSTGRES_PASSWORD:?}"
: "${POSTGRES_USER:?}"
: "${POSTGRES_DB:?}"
: "${CLICKHOUSE_PASSWORD:?}"

echo "==> Setting project to ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}"

# ── Enable required APIs ───────────────────────────────────────────────────────
echo "==> Enabling required APIs..."
gcloud services enable \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  storage.googleapis.com \
  iam.googleapis.com \
  --project="${PROJECT_ID}"

# ── Artifact Registry repository ──────────────────────────────────────────────
echo "==> Creating Artifact Registry repo: ${ARTIFACT_REGISTRY_REPO}"
gcloud artifacts repositories create "${ARTIFACT_REGISTRY_REPO}" \
  --repository-format=docker \
  --location="${REGION}" \
  --description="Langfuse Cloud Run images" \
  --project="${PROJECT_ID}" 2>/dev/null || echo "    (already exists)"

# ── GCS bucket for WAL archives and base backups ──────────────────────────────
echo "==> Creating GCS bucket: gs://${GCS_WAL_BUCKET}"
gcloud storage buckets create "gs://${GCS_WAL_BUCKET}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --uniform-bucket-level-access 2>/dev/null || echo "    (already exists)"

# Enable versioning so accidental deletes are recoverable
gcloud storage buckets update "gs://${GCS_WAL_BUCKET}" \
  --versioning

# Lifecycle: delete WAL segments older than 14 days (base backups kept forever)
gcloud storage buckets update "gs://${GCS_WAL_BUCKET}" \
  --lifecycle-file=- <<'EOF'
{
  "rule": [
    {
      "action": {"type": "Delete"},
      "condition": {
        "age": 14,
        "matchesPrefix": ["wal/"]
      }
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

# Grant the SA permission to read/write the WAL bucket
echo "==> Granting Storage Object Admin on gs://${GCS_WAL_BUCKET}"
gcloud storage buckets add-iam-policy-binding "gs://${GCS_WAL_BUCKET}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/storage.objectAdmin"

# Grant the SA permission to read secrets
echo "==> Granting Secret Manager Secret Accessor"
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor"

# ── Create secrets in Secret Manager ─────────────────────────────────────────
echo "==> Creating secrets in Secret Manager..."

create_or_update_secret() {
  local name="$1"
  local value="$2"
  if gcloud secrets describe "${name}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    echo "    Updating secret: ${name}"
    echo -n "${value}" | gcloud secrets versions add "${name}" \
      --data-file=- --project="${PROJECT_ID}"
  else
    echo "    Creating secret: ${name}"
    echo -n "${value}" | gcloud secrets create "${name}" \
      --data-file=- --project="${PROJECT_ID}" --replication-policy=automatic
  fi
}

# Database connection URL (used by Langfuse web and worker)
DB_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:5432/${POSTGRES_DB}"

create_or_update_secret "langfuse-db-password"        "${POSTGRES_PASSWORD}"
create_or_update_secret "langfuse-database-url"       "${DB_URL}"
create_or_update_secret "langfuse-nextauth-secret"    "${NEXTAUTH_SECRET}"
create_or_update_secret "langfuse-salt"               "${SALT}"
create_or_update_secret "langfuse-encryption-key"     "${ENCRYPTION_KEY}"
create_or_update_secret "langfuse-clickhouse-password" "${CLICKHOUSE_PASSWORD}"

# ── HMAC key for GCS S3-compatible API (Langfuse blob storage) ───────────────
echo "==> Creating HMAC key for GCS S3 interoperability..."
HMAC_OUTPUT=$(gcloud storage hmac create "${SA_EMAIL}" \
  --project="${PROJECT_ID}" --format=json 2>/dev/null || echo "SKIP")

if [ "${HMAC_OUTPUT}" != "SKIP" ]; then
  HMAC_ACCESS=$(echo "${HMAC_OUTPUT}" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d['metadata']['accessId'])")
  HMAC_SECRET=$(echo "${HMAC_OUTPUT}" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d['secret'])")
  create_or_update_secret "langfuse-gcs-hmac-key"    "${HMAC_ACCESS}"
  create_or_update_secret "langfuse-gcs-hmac-secret" "${HMAC_SECRET}"
else
  echo "    HMAC key may already exist. Create manually if needed:"
  echo "    gcloud storage hmac create ${SA_EMAIL} --project=${PROJECT_ID}"
fi

echo ""
echo "✓ GCP resources ready."
echo "  Next step: bash setup/02-build-and-push.sh"
