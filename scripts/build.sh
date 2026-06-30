#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_VERSION="${UPSTREAM_VERSION:-$(tr -d '[:space:]' < "$ROOT/UPSTREAM_VERSION")}"
UPSTREAM_COMMIT="${UPSTREAM_COMMIT:-$(tr -d '[:space:]' < "$ROOT/UPSTREAM_COMMIT")}"
UPSTREAM_REPOSITORY="${UPSTREAM_REPOSITORY:-the-djmaze/snappymail}"
UPSTREAM_TAG="${UPSTREAM_TAG:-v${UPSTREAM_VERSION}}"
UPSTREAM_CORE_ASSET="${UPSTREAM_CORE_ASSET:-snappymail-${UPSTREAM_VERSION}.tar.gz}"
UPSTREAM_CORE_URL="${UPSTREAM_CORE_URL:-https://github.com/${UPSTREAM_REPOSITORY}/releases/download/${UPSTREAM_TAG}/${UPSTREAM_CORE_ASSET}}"
UPSTREAM_SOURCE_URL="${UPSTREAM_SOURCE_URL:-https://github.com/${UPSTREAM_REPOSITORY}/archive/${UPSTREAM_COMMIT}.tar.gz}"
EXPECTED_CORE_SHA_FILE="${EXPECTED_CORE_SHA_FILE:-$ROOT/UPSTREAM_CORE_SHA256}"
EXPECTED_SOURCE_SHA_FILE="${EXPECTED_SOURCE_SHA_FILE:-$ROOT/UPSTREAM_SOURCE_SHA256}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
WORK_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

verify_sha256() {
    local archive="$1"
    local expected_file="$2"
    local label="$3"
    local actual expected

    actual="$(sha256sum "$archive" | awk '{print $1}')"
    printf '    %s SHA256: %s\n' "$label" "$actual" >&2

    if [[ -s "$expected_file" ]]; then
        expected="$(tr -d '[:space:]' < "$expected_file")"
        if [[ "$actual" != "$expected" ]]; then
            echo "ERROR: $label SHA256 does not match $expected_file" >&2
            echo "ERROR: Expected $expected" >&2
            echo "ERROR: Received $actual" >&2
            exit 1
        fi
        printf '    %s SHA256 verification passed\n' "$label" >&2
    else
        printf '    WARNING: %s SHA256 is not pinned yet; recording it for review\n' "$label" >&2
    fi

    printf '%s\n' "$actual"
}

download() {
    local url="$1"
    local destination="$2"

    curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 5 \
        --retry-delay 2 \
        --retry-all-errors \
        --connect-timeout 20 \
        --max-time 300 \
        "$url" \
        --output "$destination"
}

printf '==> Using pinned SnappyMail inputs\n'
printf '    Repository: %s\n' "$UPSTREAM_REPOSITORY"
printf '    Tag:        %s\n' "$UPSTREAM_TAG"
printf '    Commit:     %s\n' "$UPSTREAM_COMMIT"
printf '    Core asset: %s\n' "$UPSTREAM_CORE_ASSET"
printf '    Core URL:   %s\n' "$UPSTREAM_CORE_URL"
printf '    Source URL: %s\n' "$UPSTREAM_SOURCE_URL"

CORE_ARCHIVE="$WORK_DIR/$UPSTREAM_CORE_ASSET"
SOURCE_ARCHIVE="$WORK_DIR/snappymail-source-${UPSTREAM_COMMIT}.tar.gz"

echo '==> Downloading pinned core and source archives'
download "$UPSTREAM_CORE_URL" "$CORE_ARCHIVE"
download "$UPSTREAM_SOURCE_URL" "$SOURCE_ARCHIVE"

CORE_SHA256="$(verify_sha256 "$CORE_ARCHIVE" "$EXPECTED_CORE_SHA_FILE" 'Core')"
SOURCE_SHA256="$(verify_sha256 "$SOURCE_ARCHIVE" "$EXPECTED_SOURCE_SHA_FILE" 'Source')"

echo '==> Extracting upstream archives'
CORE_DIR="$WORK_DIR/core"
SOURCE_DIR="$WORK_DIR/source"
mkdir -p "$CORE_DIR" "$SOURCE_DIR"
tar -xzf "$CORE_ARCHIVE" -C "$CORE_DIR"
tar -xzf "$SOURCE_ARCHIVE" -C "$SOURCE_DIR" --strip-components=1

for required in \
    "$CORE_DIR/snappymail/v/$UPSTREAM_VERSION" \
    "$CORE_DIR/index.php" \
    "$CORE_DIR/.htaccess" \
    "$SOURCE_DIR/integrations/nextcloud/snappymail/appinfo/info.xml" \
    "$SOURCE_DIR/plugins/nextcloud/index.php" \
    "$SOURCE_DIR/dev/serviceworker.js"; do
    [[ -e "$required" ]] || {
        echo "ERROR: Required upstream payload is missing: $required" >&2
        exit 1
    }
done

echo '==> Assembling complete unsigned Nextcloud application'
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cp -a "$SOURCE_DIR/integrations/nextcloud/snappymail" "$BUILD_DIR/snappymail"
APP="$BUILD_DIR/snappymail"

printf '%s\n' "$UPSTREAM_VERSION" > "$APP/VERSION"
mkdir -p "$APP/app" "$APP/resources/plugins"
cp -a "$CORE_DIR/snappymail" "$APP/app/snappymail"
cp "$CORE_DIR/index.php" "$APP/app/index.php"
cp "$CORE_DIR/.htaccess" "$APP/app/_htaccess"
cp "$CORE_DIR/README.md" "$APP/app/README.md"
cp "$SOURCE_DIR/CHANGELOG.md" "$APP/CHANGELOG.md"
cp "$SOURCE_DIR/dev/serviceworker.js" "$APP/app/serviceworker.js"
cp -a "$SOURCE_DIR/plugins/nextcloud" "$APP/resources/plugins/nextcloud"

for patch_file in "$ROOT"/patches/*.patch; do
    [[ -e "$patch_file" ]] || continue
    printf '==> Applying %s\n' "$(basename "$patch_file")"
    patch --batch --forward --directory="$APP" -p1 < "$patch_file"
done

# The locally assembled app is intentionally unsigned. A stale upstream
# signature would incorrectly claim that the patched files were untouched.
rm -f "$APP/appinfo/signature.json"

printf '%s\n' "$UPSTREAM_VERSION" > "$BUILD_DIR/UPSTREAM_VERSION"
printf '%s\n' "$UPSTREAM_REPOSITORY" > "$BUILD_DIR/UPSTREAM_REPOSITORY"
printf '%s\n' "$UPSTREAM_TAG" > "$BUILD_DIR/UPSTREAM_TAG"
printf '%s\n' "$UPSTREAM_COMMIT" > "$BUILD_DIR/UPSTREAM_COMMIT"
printf '%s\n' "$UPSTREAM_CORE_ASSET" > "$BUILD_DIR/UPSTREAM_CORE_ASSET"
printf '%s\n' "$UPSTREAM_CORE_URL" > "$BUILD_DIR/UPSTREAM_CORE_URL"
printf '%s\n' "$CORE_SHA256" > "$BUILD_DIR/UPSTREAM_CORE_SHA256"
printf '%s\n' "$UPSTREAM_SOURCE_URL" > "$BUILD_DIR/UPSTREAM_SOURCE_URL"
printf '%s\n' "$SOURCE_SHA256" > "$BUILD_DIR/UPSTREAM_SOURCE_SHA256"

printf '==> Running compatibility checks\n'
"$ROOT/scripts/check-compat.sh" "$APP"

PACKAGE_NAME="snappymail-nextcloud-nc33-${UPSTREAM_VERSION}-doap.tar.gz"
PACKAGE="$BUILD_DIR/$PACKAGE_NAME"
tar -czf "$PACKAGE" -C "$BUILD_DIR" snappymail
(
    cd "$BUILD_DIR"
    sha256sum "$PACKAGE_NAME" > "$PACKAGE_NAME.sha256"
    sha256sum -c "$PACKAGE_NAME.sha256"
)

printf '==> Build complete\n'
printf '    App:     %s\n' "$APP"
printf '    Package: %s\n' "$PACKAGE"
printf '    SHA256:  %s\n' "$PACKAGE.sha256"
