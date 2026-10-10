#!/usr/bin/env bash
#
# Create the tables, the row-level security rules and the demo data (setup-db).
#
# The function is safe to run on every release: when the tables exist it changes nothing
# except re-reading the hr_app password from Secrets Manager. Aurora scales to zero when
# idle, so the first call after a quiet period can time out while the database wakes.
# That is why this tries three times.
#
# Known limit: the SQL files run only on an empty database. A change to lambda/db/*.sql is
# not applied to an existing one. A real migration tool (Flyway, Alembic) would fix that.

set -euo pipefail

cd "$(dirname "$0")/../.."

: "${FUNCTIONS_SETUP_DB:?}"

for attempt in 1 2 3; do
  echo "setup-db, attempt $attempt"
  if bash scripts/ci/invoke.sh "$FUNCTIONS_SETUP_DB" build/setup.json '{}' 300; then
    cat build/setup.json
    echo
    exit 0
  fi
  sleep 20
done

echo "setup-db did not succeed after three attempts." >&2
exit 1
