#!/usr/bin/env bash
#
# Publish the dependency layer, but only when lambda/requirements.txt has changed.
#
# How it knows: every layer version is published with a description holding a hash of
# requirements.txt and the build script. The version currently attached to the chat
# function is read back, and if its hash matches there is nothing to do.
#
# Needs: LAYER_NAME and FUNCTIONS_CHAT (see load-settings.sh).
# Sets:  LAYER_ARN (appended to $GITHUB_ENV in Actions, printed otherwise).
# FORCE_LAYER=true rebuilds and publishes even when nothing changed.

set -euo pipefail

cd "$(dirname "$0")/../.."

: "${LAYER_NAME:?}" "${FUNCTIONS_CHAT:?}"
export PYTHON=${PYTHON:-python3}

HASH=$(cat lambda/requirements.txt scripts/build-layer.sh | sha256sum | cut -c1-16)
WANTED="requirements:$HASH"

CURRENT=$(aws lambda get-function-configuration --function-name "$FUNCTIONS_CHAT" \
  --query 'Layers[0].Arn' --output text)

LAYER_ARN=""
if [ "$CURRENT" != "None" ] && [ "${FORCE_LAYER:-false}" != "true" ]; then
  DESCRIPTION=$(aws lambda get-layer-version-by-arn --arn "$CURRENT" \
    --query 'Description' --output text)
  if [ "$DESCRIPTION" = "$WANTED" ]; then
    echo "Layer is current ($WANTED). Reusing $CURRENT"
    LAYER_ARN=$CURRENT
  fi
fi

if [ -z "$LAYER_ARN" ]; then
  echo "Building the layer ($WANTED) ..."
  bash scripts/build-layer.sh
  LAYER_ARN=$(aws lambda publish-layer-version \
    --layer-name "$LAYER_NAME" \
    --zip-file fileb://build/layer.zip \
    --compatible-runtimes python3.12 \
    --compatible-architectures x86_64 \
    --description "$WANTED" \
    --query 'LayerVersionArn' --output text)
  echo "Published $LAYER_ARN"
fi

if [ -n "${GITHUB_ENV:-}" ]; then
  echo "LAYER_ARN=$LAYER_ARN" >> "$GITHUB_ENV"
else
  echo "export LAYER_ARN=$LAYER_ARN"
fi
