#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_VERSION="${UPSTREAM_VERSION:-$(tr -d '[:space:]' < "$ROOT/UPSTREAM_VERSION")}"
UPSTREAM_REPOSITORY="${UPSTREAM_REPOSITORY:-the-djmaze/snappymail}"
UPSTREAM_TAG="${UPSTREAM_TAG:-v${UPSTREAM_VERSION}}"
UPSTREAM_RELEASE_API="${UPSTREAM_RELEASE_API:-https://api.github.com/repos/${UPSTREAM_REPOSITORY}/releases/tags/${UPSTREAM_TAG}}"
UPSTREAM_ASSET="${UPSTREAM_ASSET:-}"
UPSTREAM_PACKAGE_URL="${UPSTREAM_PACKAGE_URL:-}"
EXPECTED_SHA_FILE="${EXPECTED_SHA_FILE:-$ROOT/UPSTREAM_SHA256}"
BUILD_DIR="${BUILD_DIR:-$ROOT/build}"
WORK_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if [[ -z "$UPSTREAM_PACKAGE_URL" ]]; then
    RELEASE_JSON="$WORK_DIR/release.json"

    printf '==> Resolving pinned SnappyMail release asset from GitHub\n'
    printf '    Repository: %s\n' "$UPSTREAM_REPOSITORY"
    printf '    Tag:        %s\n' "$UPSTREAM_TAG"
    printf '    API:        %s\n' "$UPSTREAM_RELEASE_API"

    curl \
        --fail \
        --location \
        --silent \
        --show-error \
        --retry 5 \
        --retry-delay 2 \
        --retry-all-errors \
        --connect-timeout 20 \
        --max-time 120 \
        -H 'Accept: application/vnd.github+json' \
        "$UPSTREAM_RELEASE_API" \
        --output "$RELEASE_JSON"

    echo '    Published assets:'
    jq -r '.assets[]?.name | "      - \(.)"' "$RELEASE_JSON"

    if [[ -n "$UPSTREAM_ASSET" ]]; then
        UPSTREAM_PACKAGE_URL="$(
            jq -er \
                --arg asset "$UPSTREAM_ASSET" \
                '.assets[] | select(.name == $asset) | .browser_download_url' \
                "$RELEASE_JSON"
        )"
    else
        mapfile -t NEXTCLOUD_ASSETS < <(
            jq -r \
                '.assets[]
                 | select(.name | test("nextcloud"; "i"))
                 | select(.name | endswith(".tar.gz"))
                 | .browser_download_url' \
                "$RELEASE_JSON"
        )

        if (( ${#NEXTCLOUD_ASSETS[@]} != 1 )); then
            echo "ERROR: Expected exactly one Nextcloud .tar.gz asset, found ${#NEXTCLOUD_ASSETS[@]}" >&2
            echo "ERROR: Set UPSTREAM_ASSET or UPSTREAM_PACKAGE_URL explicitly after reviewing the asset list" >&2
            exit 1
        fi

        UPSTREAM_PACKAGE_URL="${NEXTCLOUD_ASSETS[0]}"
        UPSTREAM_ASSET="${UPSTREAM_PACKAGE_URL##*/}"
    fi
fi

UPSTREAM_ASSET="${UPSTREAM_ASSET:-${UPSTREAM_PACKAGE_URL##*/}}"

printf '==> Downloading pinned SnappyMail Nextcloud release asset\n'
printf '    Asset:      %s\n' "$UPSTREAM_ASSET"
printf '    URL:        %s\n' "$UPSTREAM_PACKAGE_URL"

UPSTREAM_ARCHIVE="$WORK_DIR/$UPSTREAM_ASSET"
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
    "$UPSTREAM_PACKAGE_URL" \
    --output "$UPSTREAM_ARCHIVE"

UPSTREAM_SHA256="$(sha256sum "$UPSTREAM_ARCHIVE" | awk '{print $1}')"
printf '    SHA256:     %s\n' "$UPSTREAM_SHA256"

if [[ -s "$EXPECTED_SHA_FILE" ]]; then
    EXPECTED_SHA256="$(tr -d '[:space:]' < "$EXPECTED_SHA_FILE")"
    if [[ "$UPSTREAM_SHA256" != "$EXPECTED_SHA256" ]]; then
        echo "ERROR: Upstream package SHA256 does not match $EXPECTED_SHA_FILE" >&2
        echo "ERROR: Expected $EXPECTED_SHA256" >&2
        echo "ERROR: Received $UPSTREAM_SHA256" >&2
        exit 1
    fi
    echo "    SHA256 verification passed"
else
    echo "    WARNING: No pinned SHA256 exists yet; recording this value for review"
fi

printf '==> Verifying complete application payload\n'
if ! tar -tzf "$UPSTREAM_ARCHIVE" | grep -Fxq 'snappymail/app/index.php'; then
    echo "ERROR: Release asset does not contain snappymail/app/index.php" >&2
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
printf '%s\n' "$UPSTREAM_REPOSITORY" > "$BUILD_DIR/UPSTREAM_REPOSITORY"
printf '%s\n' "$UPSTREAM_TAG" > "$BUILD_DIR/UPSTREAM_TAG"
printf '%s\n' "$UPSTREAM_ASSET" > "$BUILD_DIR/UPSTREAM_ASSET"
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
