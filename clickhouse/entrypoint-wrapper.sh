#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# clickhouse/entrypoint-wrapper.sh
#
# Wraps the stock ClickHouse entrypoint to add GCS backup/restore on cold start.
#
# Flow on every Cloud Run instance start:
#   1. Write the runtime password into users.d/ from the env var
#   2. Check GCS for an existing backup (.backup metadata file)
#   3a. Backup found → start ClickHouse daemon, wait for ready, RESTORE, stop daemon
#   3b. No backup   → skip restore (Langfuse migrations will populate the schema)
#   4. exec ClickHouse in the foreground as PID 1
#
# Environment variables expected:
#   CLICKHOUSE_PASSWORD   – password for the `default` user
#   GCS_WAL_BUCKET        – GCS bucket (same bucket used for AlloyDB WAL)
#   GCS_HMAC_ACCESS_KEY   – HMAC access key ID for GCS S3-compatible API
#   GCS_HMAC_SECRET_KEY   – HMAC secret key for GCS S3-compatible API
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

: "${CLICKHOUSE_PASSWORD:?CLICKHOUSE_PASSWORD is required}"
: "${GCS_WAL_BUCKET:?GCS_WAL_BUCKET is required}"
: "${GCS_HMAC_ACCESS_KEY:?GCS_HMAC_ACCESS_KEY is required}"
: "${GCS_HMAC_SECRET_KEY:?GCS_HMAC_SECRET_KEY is required}"

CH_USER="default"
GCS_BACKUP_PREFIX="gs://${GCS_WAL_BUCKET}/clickhouse-backup/latest"
# ClickHouse uses the S3-compatible GCS endpoint for BACKUP / RESTORE
GCS_S3_BACKUP_URL="https://storage.googleapis.com/${GCS_WAL_BUCKET}/clickhouse-backup/latest"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] [clickhouse-init] $*" >&2; }

# ── 1. Write runtime password config ──────────────────────────────────────────
# ClickHouse merges files under /etc/clickhouse-server/users.d/ at startup.
# We write the password here so it never appears in a baked image layer.
mkdir -p /etc/clickhouse-server/users.d
cat > /etc/clickhouse-server/users.d/99-runtime-password.xml <<EOF
<clickhouse>
    <users>
        <default>
            <password>${CLICKHOUSE_PASSWORD}</password>
        </default>
    </users>
</clickhouse>
EOF
log "Runtime password config written"

# ── 2. Check GCS for an existing backup ───────────────────────────────────────
# ClickHouse native BACKUP writes a `.backup` manifest at the root of the path.
NEEDS_RESTORE=false
if gcloud storage ls "${GCS_BACKUP_PREFIX}/.backup" >/dev/null 2>&1; then
    log "Found ClickHouse backup at ${GCS_BACKUP_PREFIX}"
    NEEDS_RESTORE=true
else
    log "No ClickHouse backup found in GCS — will start with an empty database."
    log "(Run scripts/backup-now.sh after Langfuse has initialised its schema.)"
fi

# ── 3. Restore from GCS (if backup exists) ────────────────────────────────────
if [ "${NEEDS_RESTORE}" = "true" ]; then
    log "Starting ClickHouse daemon for restore..."
    clickhouse-server \
        --config=/etc/clickhouse-server/config.xml \
        --daemon \
        --pid-file=/tmp/clickhouse-daemon.pid

    # Wait up to 60 s for ClickHouse to accept connections
    log "Waiting for ClickHouse daemon to become ready..."
    READY=false
    for i in $(seq 1 60); do
        if clickhouse-client \
                --user="${CH_USER}" \
                --password="${CLICKHOUSE_PASSWORD}" \
                --query="SELECT 1" >/dev/null 2>&1; then
            log "ClickHouse ready after ${i}s"
            READY=true
            break
        fi
        sleep 1
    done

    if [ "${READY}" != "true" ]; then
        log "ERROR: ClickHouse daemon did not become ready in time — aborting restore."
        exit 1
    fi

    log "Running RESTORE from ${GCS_S3_BACKUP_URL} ..."
    clickhouse-client \
        --user="${CH_USER}" \
        --password="${CLICKHOUSE_PASSWORD}" \
        --query="RESTORE ALL FROM S3(
            '${GCS_S3_BACKUP_URL}',
            '${GCS_HMAC_ACCESS_KEY}',
            '${GCS_HMAC_SECRET_KEY}'
        ) SETTINGS allow_s3_native_copy=1, allow_non_empty_tables=true"

    log "Restore complete — shutting down daemon..."
    clickhouse-client \
        --user="${CH_USER}" \
        --password="${CLICKHOUSE_PASSWORD}" \
        --query="SYSTEM SHUTDOWN" 2>/dev/null || true

    # Wait for the daemon PID to exit (up to 30 s)
    for i in $(seq 1 30); do
        [ ! -f /tmp/clickhouse-daemon.pid ] && break
        PID=$(cat /tmp/clickhouse-daemon.pid 2>/dev/null || echo "")
        [ -z "${PID}" ] && break
        kill -0 "${PID}" 2>/dev/null || break
        sleep 1
    done
    log "Daemon stopped — handing off to foreground ClickHouse"
fi

# ── 4. Start ClickHouse as PID 1 in the foreground ────────────────────────────
log "Starting ClickHouse server (foreground)..."
exec /entrypoint.sh
