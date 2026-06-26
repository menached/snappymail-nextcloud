#!/usr/bin/env bash
set -euo pipefail

APP="${1:?Usage: check-compat.sh /path/to/snappymail-app}"
INFO="$APP/appinfo/info.xml"
CONTROLLER="$APP/lib/Controller/PageController.php"

printf '==> Verifying application structure\n'
[[ -f "$INFO" ]] || { echo "ERROR: Missing $INFO" >&2; exit 1; }
[[ -f "$CONTROLLER" ]] || { echo "ERROR: Missing $CONTROLLER" >&2; exit 1; }

printf '==> Verifying Nextcloud compatibility declaration\n'
if grep -Eq '<nextcloud[^>]+max-version="(2[0-9]|30)"' "$INFO"; then
    echo "ERROR: App still declares a Nextcloud maximum version below 31" >&2
    grep -n '<nextcloud ' "$INFO" >&2 || true
    exit 1
fi

grep -n '<nextcloud ' "$INFO"

printf '==> Checking removed Nextcloud APIs\n'
if grep -RFn --exclude='*.patch' 'getNavigationManager()' "$APP"; then
    echo "ERROR: Removed OC\\Server::getNavigationManager() API remains" >&2
    exit 1
fi

printf '==> Checking navigation manager injection\n'
grep -Fq 'use OCP\INavigationManager;' "$CONTROLLER" || {
    echo "ERROR: PageController does not import INavigationManager" >&2
    exit 1
}
grep -Fq 'private INavigationManager $navigationManager' "$CONTROLLER" || {
    echo "ERROR: PageController does not inject INavigationManager" >&2
    exit 1
}

printf '==> PHP syntax validation\n'
while IFS= read -r -d '' php_file; do
    php -l "$php_file" >/dev/null
done < <(find "$APP" -type f -name '*.php' -print0)

printf '==> Looking for the bundled Nextcloud SnappyMail plugin\n'
if ! grep -RIl --include='*.php' 'NextcloudPlugin' "$APP/app" >/dev/null 2>&1; then
    echo "WARNING: Could not find a PHP declaration/reference for NextcloudPlugin in the bundled app"
    echo "WARNING: Runtime plugin-loading validation remains required"
fi

printf '==> Compatibility checks passed\n'
