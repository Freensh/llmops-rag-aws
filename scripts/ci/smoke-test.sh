#!/usr/bin/env bash
#
# Prove the deployed stack answers, and wake it up.
#
#   1. A request with no token is refused (the API is locked).
#   2. A demo user can sign in through the CI app client.
#   3. /api/me answers with that user's record.
#   4. A real question gets an answer. This is also the warm-up: Aurora and OpenSearch
#      both scale down when idle, and the first question after that can take longer than
#      the API's 29 second limit. The request is retried until the stack is awake.
#
# Needs: API_ENDPOINT, COGNITO_CI_CLIENT_ID, PROJECT_NAME, ENVIRONMENT.

set -euo pipefail

: "${API_ENDPOINT:?}" "${COGNITO_CI_CLIENT_ID:?}" "${PROJECT_NAME:?}" "${ENVIRONMENT:?}"

SMOKE_USER=${SMOKE_USER:-amara.diallo@northwind.example}

CODE=$(curl -s -o /dev/null -w '%{http_code}' "$API_ENDPOINT/api/me")
if [ "$CODE" != "401" ]; then
  echo "Expected 401 without a token, got $CODE" >&2
  exit 1
fi
echo "No token: refused with 401, as it should be."

PASSWORD=$(aws ssm get-parameter --name "/$PROJECT_NAME/$ENVIRONMENT/ci/demo_user_password" \
  --with-decryption --query 'Parameter.Value' --output text)
[ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$PASSWORD"

TOKEN=$(aws cognito-idp initiate-auth --auth-flow USER_PASSWORD_AUTH \
  --client-id "$COGNITO_CI_CLIENT_ID" \
  --auth-parameters "USERNAME=$SMOKE_USER,PASSWORD=$PASSWORD" \
  --query 'AuthenticationResult.IdToken' --output text)
[ -n "${GITHUB_ACTIONS:-}" ] && echo "::add-mask::$TOKEN"

CODE=$(curl -s -o /tmp/me.json -w '%{http_code}' -H "Authorization: Bearer $TOKEN" "$API_ENDPOINT/api/me")
if [ "$CODE" != "200" ]; then
  echo "/api/me returned $CODE" >&2
  cat /tmp/me.json >&2
  exit 1
fi
echo "Signed in: $(cat /tmp/me.json)"

QUESTION="How many vacation days can I carry over?"
for attempt in 1 2 3 4; do
  echo "Asking a question, attempt $attempt ..."
  CODE=$(curl -s --max-time 120 -o /tmp/chat.json -w '%{http_code}' \
    -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
    -d "{\"question\": \"$QUESTION\"}" "$API_ENDPOINT/api/chat" || echo "000")
  if [ "$CODE" = "200" ]; then
    echo "Answered:"
    head -c 600 /tmp/chat.json
    echo
    exit 0
  fi
  echo "Got $CODE. The stack is probably waking up."
  sleep 15
done

echo "The assistant did not answer after four attempts." >&2
exit 1
