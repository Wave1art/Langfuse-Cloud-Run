# ──────────────────────────────────────────────────────────────────────────────
# clickhouse/Dockerfile
#
# ClickHouse server with Google Cloud CLI for GCS-backed backup/restore.
#
# On every Cloud Run cold start (empty ephemeral disk):
#   1. entrypoint-wrapper.sh detects no data
#   2. Starts ClickHouse as a background daemon
#   3. Waits for it to accept connections
#   4. Runs RESTORE from the latest GCS backup (native S3-compatible API)
#   5. Shuts the daemon down cleanly
#   6. exec-s ClickHouse in the foreground as PID 1
#
# If no GCS backup exists yet (first ever run) steps 3-5 are skipped and
# ClickHouse starts with an empty database; Langfuse migrations populate it.
# A first backup is then taken via scripts/backup-now.sh.
#
# Required env vars at runtime:
#   CLICKHOUSE_PASSWORD    – password for the `default` user
#   GCS_WAL_BUCKET         – GCS bucket name (shared with AlloyDB WAL)
#   GCS_HMAC_ACCESS_KEY    – HMAC access key (GCS S3-compatible API)
#   GCS_HMAC_SECRET_KEY    – HMAC secret key
# ──────────────────────────────────────────────────────────────────────────────
FROM clickhouse/clickhouse-server:24

USER root

# Install Google Cloud CLI (needed to check for backup existence via gcloud storage ls)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg && \
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] \
https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-cloud-cli && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY config.d/99-cloudrun.xml /etc/clickhouse-server/config.d/99-cloudrun.xml
COPY entrypoint-wrapper.sh    /entrypoint-wrapper.sh
RUN chmod +x /entrypoint-wrapper.sh

ENTRYPOINT ["/entrypoint-wrapper.sh"]
