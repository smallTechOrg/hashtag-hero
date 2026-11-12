#!/usr/bin/env bash
# Deploy #hero to Cloud Run (request-based billing, scale to zero, no startup CPU boost). Files live on a GCS bucket
# mounted at /data; the database is reached over the VPC (private IP).
#   PROJECT=my-gcp-project REGION=us-central1 BUCKET=my-hero-data \
#   HERO_ANTHROPIC_API_KEY=... HERO_ANTHROPIC_WORKSPACE_ID=... HERO_GOOGLE_MAPS_API_KEY=... \
#   HERO_ADMIN_PASSWORD=... HERO_DATABASE_URL=... ./deploy/cloudrun.sh
# The app's secrets come from the environment (GitHub repository secrets in CI) and are passed to the service as
# environment variables; nothing is read from Secret Manager.
# The database URL looks like  postgresql+psycopg://hero:PASSWORD@PRIVATE_IP:5432/hero
set -euo pipefail
: "${PROJECT:?set PROJECT}" "${REGION:=us-central1}" "${BUCKET:?set BUCKET (GCS bucket for /data)}"
: "${HERO_ANTHROPIC_API_KEY:?}" "${HERO_ANTHROPIC_WORKSPACE_ID:?}" "${HERO_GOOGLE_MAPS_API_KEY:?}" "${HERO_ADMIN_PASSWORD:?}" "${HERO_DATABASE_URL:?}"
SERVICE="${SERVICE:-hero}"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT}/hero/hero:$(git rev-parse --short HEAD)"

gcloud --project "$PROJECT" artifacts repositories describe hero --location "$REGION" >/dev/null 2>&1 \
  || gcloud --project "$PROJECT" artifacts repositories create hero --repository-format docker --location "$REGION"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
docker build -t "$IMAGE" .
docker push "$IMAGE"

# YAML env file (not --set-env-vars) so secret values containing commas or colons need no escaping.
ENV_FILE="$(mktemp)"; trap 'rm -f "$ENV_FILE"' EXIT
python3 - "$ENV_FILE" <<'PY'
import json, os, sys
keys = ["HERO_ANTHROPIC_API_KEY", "HERO_ANTHROPIC_WORKSPACE_ID", "HERO_GOOGLE_MAPS_API_KEY", "HERO_ADMIN_PASSWORD", "HERO_DATABASE_URL"]
env = {k: os.environ[k] for k in keys}
env.update(HERO_DATA_DIR="/data", HERO_CLAUDE_BUDGET_USD=os.environ.get("HERO_CLAUDE_BUDGET_USD", "50"), HERO_LOG_LEVEL="INFO")
open(sys.argv[1], "w").write("\n".join(f"{k}: {json.dumps(v)}" for k, v in env.items()) + "\n")
PY

# gcloud refuses to replace a secret-typed variable with a plain one, so first drop any old Secret Manager references
# (no traffic moves; the revision this creates may not start without its variables, which is fine: the deploy below
# creates the real one and takes the traffic).
gcloud --project "$PROJECT" run services update "$SERVICE" --region "$REGION" --no-traffic --clear-secrets --quiet || true

gcloud --project "$PROJECT" run deploy "$SERVICE" --region "$REGION" --image "$IMAGE" \
  --allow-unauthenticated --execution-environment gen2 --cpu 2 --memory 4Gi --timeout 3600 \
  --min-instances 0 --max-instances 1 --cpu-throttling --no-cpu-boost --concurrency 40 \
  --network default --subnet default --vpc-egress private-ranges-only \
  --add-volume "name=data,type=cloud-storage,bucket=${BUCKET}" --add-volume-mount "volume=data,mount-path=/data" \
  --env-vars-file "$ENV_FILE"

# The --no-traffic step above pins traffic to the old revision; send it to the latest one.
gcloud --project "$PROJECT" run services update-traffic "$SERVICE" --region "$REGION" --to-latest

gcloud --project "$PROJECT" run services describe "$SERVICE" --region "$REGION" --format 'value(status.url)'
