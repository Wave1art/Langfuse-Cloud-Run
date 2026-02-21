#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# scripts/backup-now.sh
#
# Triggers an on-demand base backup from the running Cloud Run service.
# Connects to the alloydb-omni container via `gcloud run services exec` and
# runs pg_basebackup, streaming the result to GCS.
#
# Usage:
#   bash scripts/backup-now.sh [TIMESTAMP_TAG]
#
# TIMESTAMP_TAG defaults to the current UTC datetime (e.g. 2025-01-15T10-30-00Z).
# The backup is uploaded to:
#   gs://${GCS_WAL_BUCKET}/basebackup/base.tar.gz          (latest — used for restore)
#   gs://${GCS_WAL_BUCKET}/basebackup/base-TIMESTAMP.tar.gz (timestamped copy)
#
# Prerequisites:
#   • .env loaded
#   • `gcloud` authenticated with run.admin permission
#   • Cloud Run service already running
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
: "${GCS_WAL_BUCKET:?}"
: "${POSTGRES_USER:?}"
: "${POSTGRES_DB:?}"

TIMESTAMP="${1:-$(date -u '+%Y-%m-%dT%H-%M-%SZ')}"
GCS_LATEST="gs://${GCS_WAL_BUCKET}/basebackup/base.tar.gz"
GCS_TIMESTAMPED="gs://${GCS_WAL_BUCKET}/basebackup/base-${TIMESTAMP}.tar.gz"

echo "==> Taking base backup at ${TIMESTAMP}..."
echo "    Latest:      ${GCS_LATEST}"
echo "    Timestamped: ${GCS_TIMESTAMPED}"

# Run pg_basebackup inside the alloydb-omni container and pipe to GCS
gcloud run services exec "${SERVICE_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --container=alloydb-omni \
  -- bash -c "
    set -eo pipefail
    pg_basebackup \
      --host=/var/run/postgresql \
      --username='${POSTGRES_USER}' \
      --pgdata=- \
      --format=tar \
      --gzip \
      --compress=6 \
      --checkpoint=fast \
      --wal-method=none \
      --no-password \
      2>/dev/null \
      | tee >(gcloud storage cp - '${GCS_TIMESTAMPED}') \
      | gcloud storage cp - '${GCS_LATEST}'
    echo 'Backup complete'
  "

echo ""
echo "✓ Base backup written to:"
echo "  ${GCS_LATEST}"
echo "  ${GCS_TIMESTAMPED}"
echo ""
echo "  WAL segments continue to archive automatically."
echo "  To restore to this point use: bash scripts/restore-from-archive.sh"
