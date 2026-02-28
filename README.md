# Langfuse on Google Cloud Run

Fully self-hosted [Langfuse](https://langfuse.com) running on **Google Cloud Run** with a multi-container sidecar architecture.  No Kubernetes, no persistent VMs, no managed database required.

## Architecture

```
Cloud Run Service  (single instance, always-on CPU)
├── alloydb-omni     AlloyDB Omni (PostgreSQL-compatible)
│                      • Writes to ephemeral local SSD
│                      • Archives WAL segments to GCS on every segment switch (≤5 min)
│                      • Restores from GCS base backup on every cold start
│
├── valkey           Valkey 7 (open-source Redis fork)
│                      • In-process cache and queue for Langfuse
│                      • RDB snapshot to ephemeral disk
│
├── langfuse-worker  Langfuse background processor (sidecar)
│
└── langfuse-web     Langfuse Next.js UI + REST/SDK API  ← ingress (port 3000)
```

All four containers share the same **localhost** network namespace, so they communicate without any service-discovery overhead.

### Data durability model

| Layer | Storage | Durability |
|---|---|---|
| PostgreSQL data | Ephemeral SSD (lost on restart) | WAL archived to GCS every ≤5 min |
| Base backup | GCS `basebackup/base.tar.gz` | Durable object storage |
| WAL segments | GCS `wal/` prefix | 14-day lifecycle, then deleted |
| Langfuse blobs | GCS (S3-compatible API) | Durable object storage |

On every **cold start** the `alloydb-omni` container:
1. Detects an empty data directory
2. Downloads the latest base backup from GCS
3. Replays archived WAL segments to reach the most recent consistent state
4. Signals PostgreSQL to promote and start accepting connections

Maximum data loss window = the WAL archive lag, typically **< 5 minutes**.

## Prerequisites

- Google Cloud project with billing enabled
- `gcloud` CLI installed and authenticated
- Docker (for building the AlloyDB Omni image)
- `envsubst` (part of `gettext`, available via `brew install gettext` or `apt install gettext-base`)

## Deployment Variants

Two variants are provided.  Choose based on your access level:

| | **Secret Manager** (default) | **Plain env** (no Secret Manager) |
|---|---|---|
| Scripts | `01-gcp-resources.sh` + `03-deploy.sh` | `01-gcp-resources.plain-env.sh` + `03-deploy.plain-env.sh` |
| Service spec | `cloud-run/service.yaml` | `cloud-run/service.plain-env.yaml` |
| Secret storage | Cloud Secret Manager (versioned, audited) | Cloud Run service config (encrypted at rest) |
| Who can read secrets | Principals with `secretmanager.secretAccessor` | Principals with `run.services.get` (broader) |
| GCP APIs required | + `secretmanager.googleapis.com` | None beyond the defaults |

Both variants use `envsubst` so secrets never appear in the git repository.

---

## Quick Start — Plain env (no Secret Manager)

### 1. Configure

```bash
cp .env.example .env
# Fill in PROJECT_ID, REGION, and generate secrets:
openssl rand -hex 32   # run once each for NEXTAUTH_SECRET, SALT, ENCRYPTION_KEY, POSTGRES_PASSWORD
```

### 2. Create GCP resources

```bash
bash setup/01-gcp-resources.plain-env.sh
```

Creates the GCS bucket, Artifact Registry repo, service account, IAM bindings, and
GCS HMAC key.  The HMAC key and `DATABASE_URL` are written back into your `.env`
automatically.

### 3. Build and push the AlloyDB Omni image

```bash
bash setup/02-build-and-push.sh
```

### 4. Deploy

```bash
bash setup/03-deploy.plain-env.sh
```

Secrets are expanded inline by `envsubst` into a `mktemp` file, deployed, then the
file is immediately deleted.

On the **first deploy** `NEXTAUTH_URL` uses a placeholder.  After the URL is printed:

```bash
# Add to .env:
SERVICE_URL=your-service-abc123-uc.a.run.app

# Re-deploy:
bash setup/03-deploy.plain-env.sh
```

---

## Quick Start — Secret Manager variant

### 1. Configure

```bash
cp .env.example .env
# Fill in PROJECT_ID, REGION, and generate secrets (same as above)
```

### 2. Create GCP resources

```bash
bash setup/01-gcp-resources.sh
```

Creates everything above **plus** stores all secrets in Cloud Secret Manager.

### 3. Build and push

```bash
bash setup/02-build-and-push.sh
```

### 4. Deploy

```bash
bash setup/03-deploy.sh
```

## File Structure

```
Langfuse-Cloud-Run/
├── .env.example                              Template for environment variables
│
├── alloydb-omni/
│   ├── Dockerfile                            AlloyDB Omni + gcloud CLI
│   ├── entrypoint-wrapper.sh                 GCS restore logic (runs before initdb)
│   └── initdb.d/
│       └── 01-configure-wal-archiving.sh     WAL archiving setup + first base backup
│
├── cloud-run/
│   ├── service.yaml                          Cloud Run spec — Secret Manager variant
│   └── service.plain-env.yaml               Cloud Run spec — plain env variant
│
├── scripts/
│   ├── backup-now.sh                         Trigger an on-demand base backup
│   └── restore-from-archive.sh              Restore to a local container (PITR)
│
└── setup/
    ├── 01-gcp-resources.sh                  GCP infra + Secret Manager secrets
    ├── 01-gcp-resources.plain-env.sh        GCP infra only (no Secret Manager)
    ├── 02-build-and-push.sh                 Build and push AlloyDB Omni image (shared)
    ├── 03-deploy.sh                         Deploy — Secret Manager variant
    └── 03-deploy.plain-env.sh              Deploy — plain env variant
```

## Operations

### Take an on-demand backup

```bash
bash scripts/backup-now.sh
# or with a tag:
bash scripts/backup-now.sh 2025-01-15T10-00-00Z
```

Uploads a new `base.tar.gz` to GCS (overwrites the "latest" pointer) and keeps a timestamped copy.

### Restore from archive (local PITR)

```bash
# Restore latest backup, replay all available WAL
bash scripts/restore-from-archive.sh

# Restore to a specific point in time
bash scripts/restore-from-archive.sh --target-time "2025-01-15 10:30:00 UTC"

# Restore a specific backup snapshot
bash scripts/restore-from-archive.sh --backup-tag base-2025-01-15T10-00-00Z
```

This starts a local Docker container with the restored data.  Connect with psql to inspect or export.

**Cloud Run restore** happens automatically on every restart — no manual intervention needed.

### Force a Cloud Run restart (re-restore from GCS)

```bash
# Deletes the current revision, forcing a new cold start and GCS restore
gcloud run services update-traffic langfuse \
  --region=us-central1 \
  --to-latest
```

Or simply update any environment variable to trigger a new revision.

## Important Constraints

- **Single instance only** — `maxScale: 1` is mandatory.  The database sidecar cannot be shared across multiple instances.
- **Not zero-scale** — `minScale: 1` keeps the instance alive.  Scaling to zero would lose the in-memory Valkey state and require a full GCS restore on every request.
- **Cold start latency** — After a restart, WAL replay can take several minutes.  Cloud Run will retry the startup probe during this time.
- **Ephemeral disk** — The local SSD is lost on restart.  GCS WAL archiving is your only durability layer — ensure `GCS_WAL_BUCKET` is always set.

## Suitable Use Cases

- Development and staging environments
- Cost-sensitive single-tenant deployments
- Environments where managed database services are unavailable

For production workloads requiring high availability, consider replacing the `alloydb-omni` sidecar with [Cloud SQL](https://cloud.google.com/sql) or managed [AlloyDB](https://cloud.google.com/alloydb).
