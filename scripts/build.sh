#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_REPO="https://github.com/the-djmaze/snappymail.git"
UPSTREAM_REF="${UPSTREAM_REF:-$(tr -d '[:space:]' < "$ROOT/UPSTREAM_REF")}" 
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
WORK_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

printf '==> Resolving upstream ref: %s\n' "$UPSTREAM_REF"
UPSTREAM_COMMIT="$(git ls-remote "$UPSTREAM_REPO" "$UPSTREAM_REF" | awk 'NR == 1 {print $1}')"

if [[ -z "$UPSTREAM_COMMIT" && "$UPSTREAM_REF" =~ ^[0-9a-f]{40}$ ]]; then
    UPSTREAM_COMMIT="$UPSTREAM_REF"
fi

if [[ -z "$UPSTREAM_COMMIT" ]]; then
    echo "ERROR: Could not resolve upstream ref: $UPSTREAM_REF" >&2
    exit 1
fi

printf '==> Upstream commit: %s\n' "$UPSTREAM_COMMIT"

ARCHIVE="$WORK_DIR/upstream.tar.gz"
curl --fail --location --silent --show-error \
    "https://github.com/the-djmaze/snappymail/archive/${UPSTREAM_COMMIT}.tar.gz" \
    --output "$ARCHIVE"

tar -xzf "$ARCHIVE" -C "$WORK_DIR"
SOURCE_ROOT="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d -name 'snappymail-*' | head -n1)"
SOURCE_APP="$SOURCE_ROOT/integrations/nextcloud/snappymail"

if [[ ! -f "$SOURCE_APP/appinfo/info.xml" ]]; then
    echo "ERROR: Upstream Nextcloud integration not found" >&2
    exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cp -a "$SOURCE_APP" "$BUILD_DIR/snappymail"

for patch_file in "$ROOT"/patches/*.patch; do
    [[ -e "$patch_file" ]] || continue
    printf '==> Applying %s\n' "$(basename "$patch_file")"
    patch --batch --forward --directory="$BUILD_DIR/snappymail" -p1 < "$patch_file"
done

printf '%s\n' "$UPSTREAM_COMMIT" > "$BUILD_DIR/UPSTREAM_COMMIT"
printf '%s\n' "$UPSTREAM_REF" > "$BUILD_DIR/UPSTREAM_REF"

printf '==> Running compatibility checks\n'
"$ROOT/scripts/check-compat.sh" "$BUILD_DIR/snappymail"

PACKAGE="$BUILD_DIR/snappymail-nextcloud-nc33-${UPSTREAM_COMMIT:0:12}.tar.gz"
tar -czf "$PACKAGE" -C "$BUILD_DIR" snappymail
sha256sum "$PACKAGE" > "$PACKAGE.sha256"

printf '==> Build complete\n'
printf '    App:     %s\n' "$BUILD_DIR/snappymail"
printf '    Package: %s\n' "$PACKAGE"
printf '    SHA256:  %s\n' "$PACKAGE.sha256"
