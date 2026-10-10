#!/usr/bin/env bash
#
# Build the React app and publish it: write the Cognito settings Vite needs, build, copy to
# the front-end bucket, clear the CloudFront cache, and wait until the new files are served.
#
# The three Cognito values are public (they end up in the JavaScript any visitor can read),
# which is why they can live in SSM as plain strings.
#
# Needs: COGNITO_AUTHORITY, COGNITO_WEB_CLIENT_ID, COGNITO_DOMAIN, FRONTEND_BUCKET,
#        CLOUDFRONT_DISTRIBUTION_ID (see load-settings.sh).

set -euo pipefail

cd "$(dirname "$0")/../.."

: "${COGNITO_AUTHORITY:?}" "${COGNITO_WEB_CLIENT_ID:?}" "${COGNITO_DOMAIN:?}"
: "${FRONTEND_BUCKET:?}" "${CLOUDFRONT_DISTRIBUTION_ID:?}"

cat > frontend/.env.production <<ENV
VITE_AUTH_MODE=cognito
VITE_COGNITO_AUTHORITY=$COGNITO_AUTHORITY
VITE_COGNITO_CLIENT_ID=$COGNITO_WEB_CLIENT_ID
VITE_COGNITO_DOMAIN=$COGNITO_DOMAIN
ENV

(cd frontend && npm ci && npm run build)

aws s3 sync frontend/dist/ "s3://$FRONTEND_BUCKET/" --delete --no-progress

INVALIDATION=$(aws cloudfront create-invalidation \
  --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" --paths '/*' \
  --query 'Invalidation.Id' --output text)
echo "Invalidation $INVALIDATION started, waiting for it to complete ..."
aws cloudfront wait invalidation-completed \
  --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" --id "$INVALIDATION"
echo "Front end published."
