#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_SCRIPT="$ROOT/scripts/runtime-test-real.sh"
LOG_PATCH="$ROOT/tests/runtime-test-dovecot-log-format.patch"

[[ -f "$TEST_SCRIPT" ]] || {
    echo "ERROR: Runtime test script is missing: $TEST_SCRIPT" >&2
    exit 1
}
[[ -f "$LOG_PATCH" ]] || {
    echo "ERROR: Dovecot log-format patch is missing: $LOG_PATCH" >&2
    exit 1
}

patch --batch --forward --directory="$ROOT" -p1 < "$LOG_PATCH"
exec "$TEST_SCRIPT"
