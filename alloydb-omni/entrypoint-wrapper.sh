#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# entrypoint-wrapper.sh
#
# Runs before the standard AlloyDB Omni / PostgreSQL docker-entrypoint.sh.
# On every Cloud Run cold start the data directory is empty (ephemeral disk).
# This script checks GCS for an existing base backup and, if found, restores it
# so that PostgreSQL can replay archived WAL and reach the latest consistent
# state.  If no backup exists yet (first ever run) it lets the normal initdb
# flow proceed, which will create the backup via 01-configure-wal-archiving.sh.
#
# Environment variables expected:
#   GCS_WAL_BUCKET   – GCS bucket name (no gs:// prefix), e.g. my-project-wal
#   PGDATA           – PostgreSQL data directory (default: /var/lib/postgresql/data)
#   POSTGRES_USER    – PostgreSQL superuser (default: postgres)
# ──────────────────────────────────────────────────────────────────────────────
set -eo pipefail

DATA_DIR="${PGDATA:-/var/lib/postgresql/data}"
PG_USER="${POSTGRES_USER:-postgres}"

: "${GCS_WAL_BUCKET:?GCS_WAL_BUCKET environment variable is required}"

GCS_BACKUP_URI="gs://${GCS_WAL_BUCKET}/basebackup/base.tar.gz"
GCS_WAL_PREFIX="gs://${GCS_WAL_BUCKET}/wal"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [alloydb-init] $*" >&2; }

# ── Restore from GCS if the data directory is empty ───────────────────────────
if [ ! -f "${DATA_DIR}/PG_VERSION" ]; then
  log "Data directory is empty — checking GCS for an existing base backup..."

  mkdir -p "${DATA_DIR}"
  # Ensure the postgres OS user owns the directory before any file operations
  chown postgres:postgres "${DATA_DIR}" 2>/dev/null || true

  if gcloud storage ls "${GCS_BACKUP_URI}" >/dev/null 2>&1; then
    log "Found base backup at ${GCS_BACKUP_URI} — restoring..."

    # Stream the gzipped tar directly into the data directory
    gcloud storage cp "${GCS_BACKUP_URI}" - \
      | gosu postgres tar xzf - -C "${DATA_DIR}"

    log "Base backup extracted to ${DATA_DIR}"

    # ── Configure WAL point-in-time recovery (PostgreSQL 12+ style) ────────────
    # Instead of recovery.conf, PG12+ uses postgresql.conf + recovery.signal
    gosu postgres bash -c "cat >> '${DATA_DIR}/postgresql.conf'" <<EOF

# ── WAL recovery — appended by entrypoint-wrapper.sh on $(date -u +%FT%TZ) ──
restore_command = 'gcloud storage cp ${GCS_WAL_PREFIX}/%f %p 2>/dev/null'
recovery_target_action = 'promote'
EOF

    # Signal file that tells PostgreSQL to enter recovery mode
    gosu postgres touch "${DATA_DIR}/recovery.signal"

    log "WAL recovery configured — PostgreSQL will replay archived segments from GCS."
    log "This may take several minutes depending on the number of WAL segments."

  else
    log "No GCS backup found — AlloyDB Omni will perform a fresh initdb."
    log "(The initdb hook will take the first base backup automatically.)"
  fi

else
  log "Existing data directory found (PG_VERSION present) — skipping restore."
fi

# ── Hand off to the standard AlloyDB Omni / PostgreSQL entrypoint ─────────────
log "Handing off to AlloyDB Omni entrypoint..."
exec /docker-entrypoint.sh "$@"
