#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# 01-configure-wal-archiving.sh
#
# Placed in /docker-entrypoint-initdb.d/ so it runs automatically after a
# fresh `initdb` on the very first database start.  It:
#   1. Appends WAL archiving settings to postgresql.conf
#   2. Reloads the PostgreSQL configuration
#   3. Takes the first base backup and streams it to GCS
#
# This script only runs once — on a brand-new (empty) database.  Subsequent
# starts restore from the GCS backup via entrypoint-wrapper.sh instead.
#
# PostgreSQL is already running and listening on a Unix socket when this
# script executes.  The current user is the postgres OS user.
# ──────────────────────────────────────────────────────────────────────────────
set -eo pipefail

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [wal-init] $*"; }

if [ -z "${GCS_WAL_BUCKET}" ]; then
  log "WARNING: GCS_WAL_BUCKET is not set — skipping WAL archiving setup."
  log "         Set GCS_WAL_BUCKET to enable durable WAL archiving to GCS."
  exit 0
fi

GCS_WAL_PREFIX="gs://${GCS_WAL_BUCKET}/wal"
GCS_BACKUP_URI="gs://${GCS_WAL_BUCKET}/basebackup/base.tar.gz"
DB="${POSTGRES_DB:-${POSTGRES_USER:-postgres}}"

log "Configuring WAL archiving → ${GCS_WAL_PREFIX}"

# ── 1. Append WAL archiving settings ──────────────────────────────────────────
cat >> "${PGDATA}/postgresql.conf" <<EOF

# ── WAL Archiving to GCS — appended by 01-configure-wal-archiving.sh ─────────
wal_level          = replica
archive_mode       = on
# gcloud storage cp: authenticated via Workload Identity (no key file needed)
archive_command    = 'gcloud storage cp %p ${GCS_WAL_PREFIX}/%f && echo "archived: %f"'
# Force-archive any open WAL segment after 5 minutes of inactivity
archive_timeout    = 300
max_wal_senders    = 3
wal_keep_size      = 128
EOF

log "WAL archiving settings written to postgresql.conf"

# ── 2. Reload config so the archiver starts immediately ───────────────────────
psql -v ON_ERROR_STOP=1 \
     --username "${POSTGRES_USER}" \
     --dbname   "${DB}" \
     -c "SELECT pg_reload_conf();"

log "Configuration reloaded — WAL archiver is now active"

# Brief pause to let the archiver process spin up before we start the backup
sleep 3

# ── 3. Take initial base backup and upload to GCS ─────────────────────────────
log "Taking initial base backup → ${GCS_BACKUP_URI}"

# pg_basebackup connects via the Unix socket (no password needed here).
# --wal-method=none: we rely on continuous WAL archiving instead of bundling
# WAL into the backup tar (cleaner separation).
pg_basebackup \
  --host=/var/run/postgresql \
  --username="${POSTGRES_USER}" \
  --pgdata=- \
  --format=tar \
  --gzip \
  --compress=6 \
  --checkpoint=fast \
  --wal-method=none \
  --no-password \
  2>/dev/null \
  | gcloud storage cp - "${GCS_BACKUP_URI}"

log "Initial base backup complete → ${GCS_BACKUP_URI}"
log "WAL archiving and GCS backup are fully configured."
