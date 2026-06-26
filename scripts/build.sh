#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_VERSION="${UPSTREAM_VERSION:-$(tr -d '[:space:]' < "$ROOT/UPSTREAM_VERSION")}" 
UPSTREAM_PACKAGE_URL="${UPSTREAM_PACKAGE_URL:-https://snappymail.eu/repository/nextcloud/snappymail-${UPSTREAM_VERSION}-nextcloud.tar.gz}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
WORK_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

printf '==> Downloading official SnappyMail Nextcloud package\n'
printf '    Version: %s\n' "$UPSTREAM_VERSION"
printf '    URL:     %s\n' "$UPSTREAM_PACKAGE_URL"

UPSTREAM_ARCHIVE="$WORK_DIR/snappymail-nextcloud.tar.gz"
curl --fail --location --silent --show-error \
    "$UPSTREAM_PACKAGE_URL" \
    --output "$UPSTREAM_ARCHIVE"

UPSTREAM_SHA256="$(sha256sum "$UPSTREAM_ARCHIVE" | awk '{print $1}')"
printf '    SHA256:  %s\n' "$UPSTREAM_SHA256"

printf '==> Verifying complete application payload\n'
if ! tar -tzf "$UPSTREAM_ARCHIVE" | grep -Fxq 'snappymail/app/index.php'; then
    echo "ERROR: Official package does not contain snappymail/app/index.php" >&2
    echo "ERROR: Refusing to build an incomplete integration-only archive" >&2
    exit 1
fi

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
tar -xzf "$UPSTREAM_ARCHIVE" -C "$BUILD_DIR"

APP="$BUILD_DIR/snappymail"
if [[ ! -f "$APP/appinfo/info.xml" ]]; then
    echo "ERROR: Extracted Nextcloud app is missing appinfo/info.xml" >&2
    exit 1
fi

for patch_file in "$ROOT"/patches/*.patch; do
    [[ -e "$patch_file" ]] || continue
    printf '==> Applying %s\n' "$(basename "$patch_file")"
    patch --batch --forward --directory="$APP" -p1 < "$patch_file"
done

# The upstream signature no longer matches after applying our reviewed patches.
# An invalid signature is worse than an explicitly unsigned local fork.
rm -f "$APP/appinfo/signature.json"

printf '%s\n' "$UPSTREAM_VERSION" > "$BUILD_DIR/UPSTREAM_VERSION"
printf '%s\n' "$UPSTREAM_PACKAGE_URL" > "$BUILD_DIR/UPSTREAM_PACKAGE_URL"
printf '%s\n' "$UPSTREAM_SHA256" > "$BUILD_DIR/UPSTREAM_SHA256"

printf '==> Running compatibility checks\n'
"$ROOT/scripts/check-compat.sh" "$APP"

PACKAGE="$BUILD_DIR/snappymail-nextcloud-nc33-${UPSTREAM_VERSION}-doap.tar.gz"
tar -czf "$PACKAGE" -C "$BUILD_DIR" snappymail
sha256sum "$PACKAGE" > "$PACKAGE.sha256"

printf '==> Build complete\n'
printf '    App:     %s\n' "$APP"
printf '    Package: %s\n' "$PACKAGE"
printf '    SHA256:  %s\n' "$PACKAGE.sha256"
