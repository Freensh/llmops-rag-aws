#!/usr/bin/env bash
#
# Run promptfoo against the deployed API, then apply the gate (eval/gate.mjs).
#
# Order of events:
#   1. Ask every case that does not need a conversation history, as the right user.
#   2. Ask the cases that failed once more. A model can answer differently between two
#      identical calls, and one unlucky answer should not block a pull request.
#   3. The gate reads both runs plus the evaluate Lambda's results for the cases that need a
#      history (build/evaluation.json), and checks the rules in eval/gate.mjs.
#
# Needs: API_ENDPOINT, COGNITO_CI_CLIENT_ID, PROJECT_NAME, ENVIRONMENT (see load-settings.sh).
# Exits non-zero when the gate fails.

set -euo pipefail

cd "$(dirname "$0")/../../eval"

: "${API_ENDPOINT:?}" "${COGNITO_CI_CLIENT_ID:?}" "${PROJECT_NAME:?}" "${ENVIRONMENT:?}"

DEMO_PASSWORD=$(aws ssm get-parameter --name "/$PROJECT_NAME/$ENVIRONMENT/ci/demo_user_password" \
  --with-decryption --query 'Parameter.Value' --output text)
[ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$DEMO_PASSWORD"
export DEMO_PASSWORD

export PROMPTFOO_DISABLE_TELEMETRY=1
export PROMPTFOO_DISABLE_UPDATE=1
export PROMPTFOO_DISABLE_SHARING=1

mkdir -p out
rm -f out/run1.json out/run2.json

# SKIP_NPM_CI=1 is for testing the gate on a machine that already has the packages installed
if [ "${SKIP_NPM_CI:-}" != "1" ]; then
  npm ci --no-audit --no-fund
fi

# promptfoo exits non-zero when a case fails. The gate decides what a failure means, so a
# failing case must not stop the script here. A crash leaves no output file, and the gate
# then fails because run1.json is missing.
npx promptfoo eval -c promptfooconfig.yaml -o out/run1.json --no-cache -j 2 --no-progress-bar || true

FAILED=$(node gate.mjs --failed out/run1.json)
if [ "$FAILED" != "[]" ]; then
  echo "Asking the failed cases once more: $FAILED"
  ONLY_KEYS_JSON="$FAILED" npx promptfoo eval -c promptfooconfig.yaml -o out/run2.json --no-cache -j 2 --no-progress-bar || true
fi

node gate.mjs --run1 out/run1.json --run2 out/run2.json --lambda ../build/evaluation.json
