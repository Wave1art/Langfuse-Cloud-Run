# Langfuse on Google Cloud Run — Project Guide

## Project Overview

This project provides a workaround solution for deploying [Langfuse](https://langfuse.com) in **constrained infrastructure environments** where traditional VM-based or Kubernetes deployments are not available or permitted. It hosts Langfuse entirely on **Google Cloud Run** with **Google Cloud Storage (GCS)** as the backing object store.

## Problem Statement

Standard Langfuse self-hosted deployments typically require persistent VMs, managed Kubernetes clusters, or other infrastructure that may not be available in locked-down or cost-sensitive environments. This project solves that by leveraging fully managed, serverless Google Cloud services.

## Architecture

### Multi-Container Cloud Run Service

The deployment uses Cloud Run's **multi-container (sidecar)** architecture to co-locate the services that Langfuse requires within a single Cloud Run service instance:

```
Cloud Run Service
├── langfuse-web       (main container — Next.js frontend + API)
├── langfuse-worker    (sidecar — background job processor)
└── [any additional sidecars, e.g. reverse proxy / health checks]
```

All containers within the service share the same network namespace, allowing them to communicate over `localhost`.

### Storage

| Component       | Google Cloud Service         |
|-----------------|------------------------------|
| Object / blob   | Google Cloud Storage (GCS)   |
| Relational DB   | Cloud SQL (PostgreSQL) or external managed Postgres |
| Cache / queue   | Redis via Memorystore or Cloud Run sidecar |

### Key Design Decisions

- **Serverless-first**: No persistent VMs or node pools required.
- **GCS as S3-compatible store**: Langfuse's S3 integration is pointed at GCS using the GCS interoperability (XML API) endpoint, allowing drop-in compatibility.
- **Multi-container sidecars**: The Langfuse worker process runs as a sidecar alongside the web container so both share environment variables and the internal network without needing separate service discovery.
- **Constrained environment friendly**: All required services are either managed by Google or containerised within Cloud Run, with no dependency on infrastructure the user cannot control.

## Repository Structure

```
Langfuse-Cloud-Run/
├── Claude.md          # This file — project guide for Claude Code
├── README.md          # High-level project description
└── ...                # Deployment configs, Dockerfiles, IaC (Terraform/gcloud)
```

## Development Guidelines

- Prefer `gcloud` CLI or Terraform for infrastructure changes.
- Keep secrets in **Google Secret Manager**; never commit credentials.
- When modifying container definitions, update all relevant `--container` flags or the Cloud Run YAML service spec together to keep the multi-container config consistent.
- Test locally with `docker compose` before pushing images, mirroring the sidecar layout.

## Deployment Notes

- Cloud Run multi-container support requires the **`run.googleapis.com/v2`** API and a service spec using `containers[].name` with explicit port declarations.
- Only the ingress container (typically `langfuse-web`) should expose port `8080`; sidecars communicate on internal ports via `localhost`.
- Set `LANGFUSE_S3_*` environment variables to the GCS XML API endpoint (`https://storage.googleapis.com`) with an HMAC key generated from a service account.

## Relevant Links

- [Langfuse Self-Hosting Docs](https://langfuse.com/docs/deployment/self-host)
- [Cloud Run Multi-Container Docs](https://cloud.google.com/run/docs/deploying#sidecars)
- [GCS S3 Interoperability](https://cloud.google.com/storage/docs/interoperability)
