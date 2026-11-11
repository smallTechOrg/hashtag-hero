# Running #hero on Cloud Run (files on GCS, database on Cloud SQL)

Everything the pipeline produces - Street View frames, satellite crops, stitched panoramas, the frozen ground and
wall photos, the exported street models - is written under `HERO_DATA_DIR`. On Cloud Run that directory is a
**GCS bucket mounted as a volume** (`/data`), so images are fetched once and kept; the admin, the runs (fetch /
fusion / regenerate) and the game all run in the cloud, nothing depends on your laptop. The SQLite file cannot live
on a bucket (no file locks), so the database is **Cloud SQL for PostgreSQL**; the code is database-agnostic
(SQLAlchemy + Alembic) and the container applies migrations at start.

## One-time setup

```bash
gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com sqladmin.googleapis.com secretmanager.googleapis.com
gcloud storage buckets create gs://MY-HERO-DATA --location=asia-south1
gcloud sql instances create hero --database-version=POSTGRES_16 --tier=db-g1-small --region=asia-south1
gcloud sql databases create hero --instance=hero
gcloud sql users create hero --instance=hero --password='CHOOSE-A-PASSWORD'
```

## CI/CD

`.github/workflows/deploy-cloudrun.yml` builds the image, pushes it to Artifact Registry and deploys to Cloud Run
(project `ai-agent-boilerplate0`, `us-central1`) on every push to `main` or the v0.1 feature branch, or by hand from
the Actions tab. Auth is keyless (Workload Identity Federation, provider `hero-github`, service account
`github-actions-deployer`). The app's secrets live only in GitHub repository secrets and are passed to the service as
environment variables: `HERO_ANTHROPIC_API_KEY`, `HERO_ANTHROPIC_WORKSPACE_ID`, `HERO_GOOGLE_MAPS_API_KEY`,
`HERO_ADMIN_PASSWORD`, `HERO_DATABASE_URL`. To deploy from a shell instead, export those and run
`PROJECT=... REGION=us-central1 BUCKET=... ./deploy/cloudrun.sh`.

The service runs single instance that scales to zero (`--min-instances 0 --max-instances 1`) on request-based billing (`--cpu-throttling`, no startup CPU boost via `--no-cpu-boost`), so CPU is only allocated while a request is being served; the fusion
runs are in-process background tasks, so keep an admin request open for their duration (or move them to a job); the request timeout is one hour for the long
admin calls. The game itself is static files plus small JSON, served by the same container.

## Moving your local data up

```bash
gcloud storage rsync -r data gs://MY-HERO-DATA --exclude 'hero.*\.db.*'
```

then re-run `Regenerate` for each street once (the exports and panoramas are content-addressed, so already-baked
files are reused). The SQLite rows are not copied: run the legacy import or re-fetch on the cloud (the Google
imagery cache in the bucket makes re-fetching free).
