#!/usr/bin/env bash
#
# Build the function zip, then put the layer and the code on all four functions.
#
# Order matters: the layer goes first, so new code never starts on libraries it does not
# have. Each update is waited for, because Lambda refuses a second update to a function
# that is still applying the first.
#
# Needs: LAYER_ARN and the FUNCTIONS_* names (see load-settings.sh and publish-layer.sh).
# This replaces scripts/deploy-code.sh in the pipeline. That script still works by hand.

set -euo pipefail

cd "$(dirname "$0")/../.."

: "${LAYER_ARN:?}" "${FUNCTIONS_CHAT:?}" "${FUNCTIONS_INGEST:?}" "${FUNCTIONS_SETUP_DB:?}" "${FUNCTIONS_EVALUATE:?}"
export PYTHON=${PYTHON:-python3}

bash scripts/build-function.sh

NAMES=("$FUNCTIONS_CHAT" "$FUNCTIONS_INGEST" "$FUNCTIONS_SETUP_DB" "$FUNCTIONS_EVALUATE")

for name in "${NAMES[@]}"; do
  echo "$name: attaching the layer"
  aws lambda update-function-configuration --function-name "$name" \
    --layers "$LAYER_ARN" --query 'LastUpdateStatus' --output text > /dev/null
  aws lambda wait function-updated --function-name "$name"

  echo "$name: uploading the code"
  aws lambda update-function-code --function-name "$name" \
    --zip-file fileb://build/function.zip --query 'LastUpdateStatus' --output text > /dev/null
  aws lambda wait function-updated --function-name "$name"
done

echo
for name in "${NAMES[@]}"; do
  STATUS=$(aws lambda get-function-configuration --function-name "$name" \
    --query 'LastUpdateStatus' --output text)
  printf '%-32s %s\n' "$name" "$STATUS"
  if [ "$STATUS" != "Successful" ]; then
    echo "$name did not finish updating." >&2
    exit 1
  fi
done
