#!/usr/bin/env bash
#
# Invoke a Lambda function, save its answer, and fail if the function itself failed.
# (aws lambda invoke exits 0 even when the function raised an error. The error is only
# reported in the FunctionError field, so it is checked here.)
#
#   bash scripts/ci/invoke.sh FUNCTION_NAME OUTPUT_FILE [JSON_PAYLOAD] [READ_TIMEOUT_SECONDS]

set -euo pipefail

FUNCTION=${1:?function name}
OUTPUT=${2:?output file}
PAYLOAD=${3:-'{}'}
TIMEOUT=${4:-300}

mkdir -p "$(dirname "$OUTPUT")"

ERROR=$(aws lambda invoke \
  --function-name "$FUNCTION" \
  --cli-binary-format raw-in-base64-out \
  --payload "$PAYLOAD" \
  --cli-read-timeout "$TIMEOUT" \
  --cli-connect-timeout 60 \
  --query 'FunctionError' --output text \
  "$OUTPUT")

if [ "$ERROR" != "None" ]; then
  echo "$FUNCTION failed with $ERROR:" >&2
  cat "$OUTPUT" >&2
  exit 1
fi
