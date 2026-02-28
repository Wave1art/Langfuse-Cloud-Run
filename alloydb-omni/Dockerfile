# ──────────────────────────────────────────────────────────────────────────────
# AlloyDB Omni + Google Cloud CLI
#
# Builds on top of the official AlloyDB Omni container image, adding:
#   • Google Cloud CLI (gcloud storage) for WAL archiving to GCS
#   • A wrapper entrypoint that restores from a GCS base backup when the
#     data directory is empty (i.e. on every fresh Cloud Run instance start).
#   • An initdb hook that configures WAL archiving and takes the first
#     base backup on a brand-new database.
#
# Required environment variables at runtime:
#   GCS_WAL_BUCKET   – name of the GCS bucket (no gs:// prefix)
#   POSTGRES_PASSWORD – password for POSTGRES_USER
#   POSTGRES_USER    – (default: langfuse)
#   POSTGRES_DB      – (default: langfuse)
# ──────────────────────────────────────────────────────────────────────────────
FROM us-docker.pkg.dev/alloydb-omni/release/alloydbomni:latest

USER root

# Install Google Cloud CLI (provides `gcloud storage cp` for WAL archiving)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        lsb-release && \
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] \
https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends google-cloud-cli && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

COPY entrypoint-wrapper.sh /entrypoint-wrapper.sh
COPY initdb.d/01-configure-wal-archiving.sh \
     /docker-entrypoint-initdb.d/01-configure-wal-archiving.sh

RUN chmod +x \
      /entrypoint-wrapper.sh \
      /docker-entrypoint-initdb.d/01-configure-wal-archiving.sh

ENTRYPOINT ["/entrypoint-wrapper.sh"]
CMD ["postgres"]
