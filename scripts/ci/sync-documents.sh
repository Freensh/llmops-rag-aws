#!/usr/bin/env bash
#
# Upload the policy documents, and let the upload trigger ingestion, only when they changed.
#
# Documents first, manifest.json last: uploading the manifest is what starts ingestion, so
# uploading it last means one rebuild of the index, after the whole set is there.
#
# "Changed" means the content hash of lambda/data/documents differs from the hash stored on
# the manifest object in S3 (as object metadata). The hash is used instead of
# `aws s3 sync` because a fresh checkout gives every file a new timestamp, which would make
# sync re-upload everything on every run.
#
# After uploading, this waits for the ingest function to log that it finished, or failed.
#
# Needs: DOCUMENTS_BUCKET and FUNCTIONS_INGEST. FORCE_INGEST=true ingests even when unchanged.

set -euo pipefail

cd "$(dirname "$0")/../.."

: "${DOCUMENTS_BUCKET:?}" "${FUNCTIONS_INGEST:?}"

DIR=lambda/data/documents
LOCAL_HASH=$(find "$DIR" -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)

REMOTE_HASH=$(aws s3api head-object --bucket "$DOCUMENTS_BUCKET" --key manifest.json \
  --query 'Metadata."docs-sha256"' --output text 2>/dev/null || echo "none")

if [ "$LOCAL_HASH" = "$REMOTE_HASH" ] && [ "${FORCE_INGEST:-false}" != "true" ]; then
  echo "Documents unchanged (${LOCAL_HASH:0:12}). Skipping upload and ingestion."
  exit 0
fi

echo "Documents changed or ingestion forced (local ${LOCAL_HASH:0:12}, bucket $REMOTE_HASH)."
START_MS=$(( $(date +%s) * 1000 ))

aws s3 cp "$DIR/" "s3://$DOCUMENTS_BUCKET/" --recursive --exclude manifest.json --no-progress
aws s3 cp "$DIR/manifest.json" "s3://$DOCUMENTS_BUCKET/manifest.json" \
  --metadata "docs-sha256=$LOCAL_HASH" --no-progress

echo "Manifest uploaded. Waiting for ingestion to finish (up to 10 minutes) ..."
LOG_GROUP="/aws/lambda/$FUNCTIONS_INGEST"

for _ in $(seq 1 60); do
  sleep 10
  MESSAGE=$(aws logs filter-log-events --log-group-name "$LOG_GROUP" --start-time "$START_MS" \
    --filter-pattern '?"chunks indexed" ?"[ERROR]" ?"timed out"' \
    --query 'events[0].message' --output text 2>/dev/null || echo "None")
  if [ "$MESSAGE" != "None" ] && [ -n "$MESSAGE" ]; then
    echo "$MESSAGE"
    if printf '%s' "$MESSAGE" | grep -q "chunks indexed"; then
      exit 0
    fi
    echo "Ingestion failed. See the log group $LOG_GROUP." >&2
    exit 1
  fi
done

echo "Ingestion did not report back within 10 minutes. See $LOG_GROUP." >&2
exit 1
