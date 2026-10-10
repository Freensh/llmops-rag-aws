#!/usr/bin/env bash
#
# Bring the containers in line with what Terraform put in S3 and Secrets Manager.
#
# Runs at every boot (langfuse.service) and whenever you want to apply a change:
#   sudo /opt/langfuse/update.sh
#
# It downloads the compose file and its config, writes .env from the secret, then pulls and
# starts the containers. Re-running it is always safe.

set -euo pipefail

# shellcheck disable=SC1091
source /etc/langfuse-host.env   # BUCKET REGION SECRET_ID DATA_VOLUME_ID COMPOSE_VERSION

cd /opt/langfuse

# update.sh itself is replaced last and atomically: bash reads a running script as it goes,
# and overwriting it in place would corrupt this very run.
aws s3 sync "s3://$BUCKET/host/" /opt/langfuse/ --region "$REGION" \
  --exclude "bootstrap.sh" --exclude "update.sh" --exclude "README.md" --only-show-errors
aws s3 cp "s3://$BUCKET/host/update.sh" /opt/langfuse/update.sh.new --region "$REGION" --only-show-errors
sed -i 's/\r$//' /opt/langfuse/update.sh.new
chmod 755 /opt/langfuse/update.sh.new
mv /opt/langfuse/update.sh.new /opt/langfuse/update.sh

# The secret's keys are already environment variable names (NEXTAUTH_SECRET, SALT, ...)
umask 077
aws secretsmanager get-secret-value --secret-id "$SECRET_ID" --region "$REGION" \
  --query SecretString --output text \
  | jq -r 'to_entries[] | "\(.key)=\(.value)"' > .env.new
{
  echo "LANGFUSE_S3_BUCKET=$BUCKET"
  echo "AWS_REGION=$REGION"
} >> .env.new
mv .env.new .env

docker compose --env-file .env pull --quiet
docker compose --env-file .env up -d --remove-orphans

echo "Langfuse and the cache are starting. Check with: docker compose -f /opt/langfuse/docker-compose.yml ps"
