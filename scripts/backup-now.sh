#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# scripts/backup-now.sh
#
# Triggers on-demand backups of BOTH databases from the running Cloud Run
# service via `gcloud run services exec`.
#
#   AlloyDB Omni  → pg_basebackup → gs://BUCKET/basebackup/base[-TAG].tar.gz
#   ClickHouse    → BACKUP ALL TO S3(...) → gs://BUCKET/clickhouse-backup/latest/
#                                           gs://BUCKET/clickhouse-backup/TAG/
#
# Usage:
#   bash scripts/backup-now.sh [TIMESTAMP_TAG]
#
# TIMESTAMP_TAG defaults to current UTC time (e.g. 2025-01-15T10-30-00Z).
#
# Prerequisites:
#   • .env present and sourced
#   • gcloud authenticated with roles/run.admin
#   • Cloud Run service running
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
: "${CLICKHOUSE_PASSWORD:?}"
: "${GCS_HMAC_ACCESS_KEY:?}"
: "${GCS_HMAC_SECRET_KEY:?}"

TIMESTAMP="${1:-$(date -u '+%Y-%m-%dT%H-%M-%SZ')}"

echo "════════════════════════════════════════════════════════════════════════"
echo "  Langfuse on-demand backup — ${TIMESTAMP}"
echo "════════════════════════════════════════════════════════════════════════"

# ── 1. AlloyDB Omni base backup ───────────────────────────────────────────────
GCS_PG_LATEST="gs://${GCS_WAL_BUCKET}/basebackup/base.tar.gz"
GCS_PG_TAGGED="gs://${GCS_WAL_BUCKET}/basebackup/base-${TIMESTAMP}.tar.gz"

echo ""
echo "==> [1/2] AlloyDB Omni base backup → ${GCS_PG_LATEST}"

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
      | tee >(gcloud storage cp - '${GCS_PG_TAGGED}') \
      | gcloud storage cp - '${GCS_PG_LATEST}'
    echo 'AlloyDB backup complete'
  "

echo "  ✓ AlloyDB backup:"
echo "    ${GCS_PG_LATEST}"
echo "    ${GCS_PG_TAGGED}"

# ── 2. ClickHouse native backup to GCS S3-compatible API ─────────────────────
# ClickHouse's BACKUP ALL creates a consistent snapshot while the server is
# running.  The S3 endpoint uses GCS HMAC credentials (S3-compatible API).
# We write to two paths: /latest/ (overwritten each time, used for restore)
# and /TAG/ (timestamped archive kept for point-in-time reference).
GCS_CH_LATEST_URL="https://storage.googleapis.com/${GCS_WAL_BUCKET}/clickhouse-backup/latest"
GCS_CH_TAGGED_URL="https://storage.googleapis.com/${GCS_WAL_BUCKET}/clickhouse-backup/${TIMESTAMP}"

echo ""
echo "==> [2/2] ClickHouse backup → gs://${GCS_WAL_BUCKET}/clickhouse-backup/latest"

gcloud run services exec "${SERVICE_NAME}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --container=clickhouse \
  -- bash -c "
    set -eo pipefail
    CH_PASS='${CLICKHOUSE_PASSWORD}'
    HMAC_KEY='${GCS_HMAC_ACCESS_KEY}'
    HMAC_SECRET='${GCS_HMAC_SECRET_KEY}'

    # Timestamped copy first (so /latest/ is always a complete, final backup)
    echo 'Writing timestamped backup...'
    clickhouse-client \
      --user=default \
      --password=\"\${CH_PASS}\" \
      --query=\"BACKUP ALL TO S3(
          '${GCS_CH_TAGGED_URL}',
          '\${HMAC_KEY}',
          '\${HMAC_SECRET}'
      ) SETTINGS allow_s3_native_copy=1\"

    # Overwrite /latest/ — this is what restore-from-archive uses
    echo 'Writing latest backup...'
    clickhouse-client \
      --user=default \
      --password=\"\${CH_PASS}\" \
      --query=\"BACKUP ALL TO S3(
          '${GCS_CH_LATEST_URL}',
          '\${HMAC_KEY}',
          '\${HMAC_SECRET}'
      ) SETTINGS allow_s3_native_copy=1, allow_non_empty_tables=true\"

    echo 'ClickHouse backup complete'
  "

echo "  ✓ ClickHouse backup:"
echo "    gs://${GCS_WAL_BUCKET}/clickhouse-backup/latest/"
echo "    gs://${GCS_WAL_BUCKET}/clickhouse-backup/${TIMESTAMP}/"

echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo "  Both backups complete."
echo "  AlloyDB WAL continues to archive automatically (≤5 min lag)."
echo "  To restore: bash scripts/restore-from-archive.sh"
echo "════════════════════════════════════════════════════════════════════════"
