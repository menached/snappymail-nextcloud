#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_SCRIPT="$ROOT/scripts/runtime-test-real.sh"
PATCHES=(
    "$ROOT/tests/runtime-test-dovecot-log-format.patch"
    "$ROOT/tests/runtime-test-logout-isolation.patch"
)

[[ -f "$TEST_SCRIPT" ]] || {
    echo "ERROR: Runtime test script is missing: $TEST_SCRIPT" >&2
    exit 1
}

for patch_file in "${PATCHES[@]}"; do
    [[ -f "$patch_file" ]] || {
        echo "ERROR: Runtime-test patch is missing: $patch_file" >&2
        exit 1
    }
    patch --batch --forward --directory="$ROOT" -p1 < "$patch_file"
done

exec "$TEST_SCRIPT"
