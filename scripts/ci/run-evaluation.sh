#!/usr/bin/env bash
#
# Run the evaluate function (the golden questions) and print the result.
#
# Writes build/evaluation.json, prints a line per failure, and exits non-zero when any
# question failed. The workflow decides what a failure means (see deploy.yml).
#
# Needs: FUNCTIONS_EVALUATE.

set -euo pipefail

cd "$(dirname "$0")/../.."

: "${FUNCTIONS_EVALUATE:?}"

bash scripts/ci/invoke.sh "$FUNCTIONS_EVALUATE" build/evaluation.json '{}' 900

PASSED=$(jq '.passed' build/evaluation.json)
TOTAL=$(jq '.total' build/evaluation.json)
echo "$PASSED of $TOTAL questions passed"
jq -r '.failures[] | "FAIL  \(.who): \(.question)  [\(.problems | join("; "))]"' build/evaluation.json

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Evaluation: $PASSED of $TOTAL passed"
    jq -r '.failures[] | "- **\(.who)**: \(.question) (\(.problems | join("; ")))"' build/evaluation.json
  } >> "$GITHUB_STEP_SUMMARY"
fi

[ "$PASSED" = "$TOTAL" ]
