#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# scripts/restore-from-archive.sh
#
# Point-in-time restore from a GCS WAL archive into a LOCAL Docker container.
# Use this to:
#   • Inspect or export data from a specific point in time
#   • Validate that your GCS backups are recoverable
#   • Perform a disaster-recovery dry run
#
# For Cloud Run restores, simply restart the service — the entrypoint-wrapper.sh
# in the alloydb-omni container restores from GCS automatically on cold start.
#
# Usage:
#   bash scripts/restore-from-archive.sh [OPTIONS]
#
# Options:
#   --target-time "2025-01-15 10:30:00 UTC"   Restore to this timestamp (PITR)
#   --backup-tag  "base-2025-01-15T10-00-00Z"  Restore a specific timestamped backup
#                                               (default: latest base.tar.gz)
#   --data-dir    /tmp/pgdata-restore           Local directory for restored data
#                                               (default: /tmp/langfuse-restore-TIMESTAMP)
#   --pg-port     5433                          Local port to expose PostgreSQL on
#                                               (default: 5433)
#   --no-start                                  Restore data only, don't start PostgreSQL
#
# Examples:
#   # Restore latest backup and replay all WAL (point-in-time = now)
#   bash scripts/restore-from-archive.sh
#
#   # Restore to a specific timestamp
#   bash scripts/restore-from-archive.sh --target-time "2025-01-15 10:30:00 UTC"
#
#   # Restore a specific backup snapshot
#   bash scripts/restore-from-archive.sh --backup-tag base-2025-01-15T10-00-00Z
#
# Prerequisites:
#   • Docker installed locally
#   • gcloud CLI authenticated with Storage Object Viewer on GCS_WAL_BUCKET
#   • .env file present
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
: "${GCS_WAL_BUCKET:?}"
: "${POSTGRES_USER:?}"
: "${POSTGRES_DB:?}"
: "${POSTGRES_PASSWORD:?}"
: "${ARTIFACT_REGISTRY_REPO:?}"

# ── Parse arguments ───────────────────────────────────────────────────────────
TARGET_TIME=""
BACKUP_TAG="latest"
DATA_DIR="/tmp/langfuse-restore-$(date -u '+%Y%m%dT%H%M%SZ')"
PG_PORT=5433
NO_START=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-time)  TARGET_TIME="$2";  shift 2 ;;
    --backup-tag)   BACKUP_TAG="$2";   shift 2 ;;
    --data-dir)     DATA_DIR="$2";     shift 2 ;;
    --pg-port)      PG_PORT="$2";      shift 2 ;;
    --no-start)     NO_START=true;     shift   ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

GCS_WAL_PREFIX="gs://${GCS_WAL_BUCKET}/wal"
ALLOYDB_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${ARTIFACT_REGISTRY_REPO}/alloydb-omni:latest"
CONTAINER_NAME="langfuse-restore-$$"

if [ "${BACKUP_TAG}" = "latest" ]; then
  GCS_BACKUP_URI="gs://${GCS_WAL_BUCKET}/basebackup/base.tar.gz"
else
  GCS_BACKUP_URI="gs://${GCS_WAL_BUCKET}/basebackup/base-${BACKUP_TAG}.tar.gz"
fi

echo "════════════════════════════════════════════════════════════════════════"
echo "  Langfuse / AlloyDB WAL Archive Restore"
echo "════════════════════════════════════════════════════════════════════════"
echo "  Backup source : ${GCS_BACKUP_URI}"
echo "  WAL prefix    : ${GCS_WAL_PREFIX}"
echo "  Target time   : ${TARGET_TIME:-'latest (all available WAL)'}"
echo "  Local data dir: ${DATA_DIR}"
echo "  Local PG port : ${PG_PORT}"
echo "════════════════════════════════════════════════════════════════════════"

# ── 1. Verify the backup exists ────────────────────────────────────────────────
echo ""
echo "==> Verifying backup exists at ${GCS_BACKUP_URI}..."
if ! gcloud storage ls "${GCS_BACKUP_URI}" >/dev/null 2>&1; then
  echo "ERROR: No backup found at ${GCS_BACKUP_URI}"
  echo "       Run scripts/backup-now.sh first."
  exit 1
fi
echo "    Found."

# ── 2. Download and extract the base backup ────────────────────────────────────
echo ""
echo "==> Downloading and extracting base backup to ${DATA_DIR}..."
mkdir -p "${DATA_DIR}"
gcloud storage cp "${GCS_BACKUP_URI}" - | tar xzf - -C "${DATA_DIR}"
echo "    Base backup extracted."

# ── 3. Write recovery configuration ───────────────────────────────────────────
echo ""
echo "==> Writing WAL recovery configuration..."

# Recovery command: fetch WAL from GCS; return 1 (not 0) when segment not found
# so PostgreSQL knows to promote rather than hang.
RESTORE_CMD="gcloud storage cp ${GCS_WAL_PREFIX}/%f %p 2>/dev/null"

cat >> "${DATA_DIR}/postgresql.conf" <<EOF

# ── WAL Recovery — written by restore-from-archive.sh on $(date -u +%FT%TZ) ──
restore_command    = '${RESTORE_CMD}'
recovery_target_action = 'promote'
EOF

# Optional: stop at a specific timestamp
if [ -n "${TARGET_TIME}" ]; then
  cat >> "${DATA_DIR}/postgresql.conf" <<EOF
recovery_target_time   = '${TARGET_TIME}'
recovery_target_inclusive = true
EOF
  echo "    PITR target: ${TARGET_TIME}"
fi

# Signal PostgreSQL to enter recovery mode (PG 12+ style)
touch "${DATA_DIR}/recovery.signal"
echo "    recovery.signal created."

if [ "${NO_START}" = "true" ]; then
  echo ""
  echo "✓ Data directory prepared at ${DATA_DIR}"
  echo "  (--no-start was set, not launching PostgreSQL)"
  exit 0
fi

# ── 4. Start a local PostgreSQL container pointing at the restored data dir ────
echo ""
echo "==> Pulling AlloyDB Omni image for local restore..."
docker pull "${ALLOYDB_IMAGE}" --quiet 2>/dev/null || true

echo "==> Starting recovery container '${CONTAINER_NAME}' on port ${PG_PORT}..."
echo "    Logs will appear below — PostgreSQL will print progress during WAL replay."
echo "    Press Ctrl-C to stop the container when done."
echo ""

# Pass the current gcloud application-default credentials into the container
# so it can fetch WAL segments from GCS.
CREDS_MOUNT=""
ADC_PATH="${HOME}/.config/gcloud/application_default_credentials.json"
if [ -f "${ADC_PATH}" ]; then
  CREDS_MOUNT="-v ${ADC_PATH}:/tmp/adc.json:ro -e GOOGLE_APPLICATION_CREDENTIALS=/tmp/adc.json"
fi

# shellcheck disable=SC2086
docker run --rm \
  --name "${CONTAINER_NAME}" \
  -p "${PG_PORT}:5432" \
  -v "${DATA_DIR}:/var/lib/postgresql/data" \
  -e PGDATA=/var/lib/postgresql/data \
  -e POSTGRES_USER="${POSTGRES_USER}" \
  -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
  -e POSTGRES_DB="${POSTGRES_DB}" \
  -e GCS_WAL_BUCKET="${GCS_WAL_BUCKET}" \
  -e GOOGLE_CLOUD_PROJECT="${PROJECT_ID}" \
  ${CREDS_MOUNT} \
  "${ALLOYDB_IMAGE}" postgres \
  -c listen_addresses='*' \
  -c log_recovery_conflict_waits=on \
  -c log_min_messages=info &

DOCKER_PID=$!

echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo "  PostgreSQL is starting and replaying WAL segments from GCS."
echo "  This may take several minutes depending on WAL volume."
echo ""
echo "  Connect with:"
echo "    psql postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@127.0.0.1:${PG_PORT}/${POSTGRES_DB}"
echo ""
echo "  When you're done, press Ctrl-C to stop."
echo "════════════════════════════════════════════════════════════════════════"

# Wait for container to exit or Ctrl-C
wait "${DOCKER_PID}" || true

echo ""
echo "✓ Restore container stopped."
echo "  Data directory preserved at: ${DATA_DIR}"
echo "  (Delete manually when done: rm -rf ${DATA_DIR})"
