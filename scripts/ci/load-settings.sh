#!/usr/bin/env bash
#
# Read the deploy settings Terraform wrote to SSM Parameter Store, and turn each one
# into an environment variable: functions/setup-db becomes FUNCTIONS_SETUP_DB,
# cognito/web_client_id becomes COGNITO_WEB_CLIENT_ID, and so on.
#
# This is how the pipeline learns the function names, buckets and Cognito ids without
# any of them being stored in GitHub. A rebuilt stack is picked up on the next run.
#
#   In GitHub Actions   the variables are appended to $GITHUB_ENV
#   On your machine     eval "$(PROJECT_NAME=northwind-hr ENVIRONMENT=dev bash scripts/ci/load-settings.sh)"

set -euo pipefail

: "${PROJECT_NAME:?Set PROJECT_NAME, for example northwind-hr}"
: "${ENVIRONMENT:?Set ENVIRONMENT, for example dev}"

PREFIX="/${PROJECT_NAME}/${ENVIRONMENT}"

# SecureString parameters (the demo password) are left out here. Scripts that need one
# ask for it by name.
LINES=$(aws ssm get-parameters-by-path --path "$PREFIX" --recursive \
  --query "Parameters[?Type=='String'].[Name,Value]" --output text)

if [ -z "$LINES" ]; then
  echo "No parameters found under $PREFIX. Has terraform apply been run for this environment?" >&2
  exit 1
fi

while IFS=$'\t' read -r name value; do
  key=${name#"$PREFIX/"}
  key=$(printf '%s' "$key" | tr 'a-z/-' 'A-Z__')
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_ENV"
    echo "loaded $key"
  else
    printf 'export %s=%q\n' "$key" "$value"
  fi
done <<< "$LINES"
