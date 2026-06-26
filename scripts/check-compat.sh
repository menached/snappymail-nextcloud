#!/usr/bin/env bash
set -euo pipefail

APP="${1:?Usage: check-compat.sh /path/to/snappymail-app}"
INFO="$APP/appinfo/info.xml"
APPLICATION="$APP/lib/AppInfo/Application.php"
CONTROLLER="$APP/lib/Controller/PageController.php"

printf '==> Verifying application structure\n'
for required_file in \
    "$INFO" \
    "$APPLICATION" \
    "$CONTROLLER" \
    "$APP/app/index.php"; do
    [[ -f "$required_file" ]] || {
        echo "ERROR: Missing $required_file" >&2
        exit 1
    }
done

printf '==> Verifying explicit Nextcloud 33 compatibility declaration\n'
if ! grep -Eq '<nextcloud[^>]+min-version="20"[^>]+max-version="33"' "$INFO"; then
    echo "ERROR: Expected explicit max-version=33 declaration" >&2
    grep -n '<nextcloud ' "$INFO" >&2 || true
    exit 1
fi
grep -n '<nextcloud ' "$INFO"

printf '==> Checking removed Nextcloud APIs\n'
if grep -RFn --exclude='*.patch' 'getNavigationManager()' "$APP"; then
    echo "ERROR: Removed OC\\Server::getNavigationManager() API remains" >&2
    exit 1
fi

printf '==> Checking navigation manager dependency injection\n'
grep -Fq 'use OCP\INavigationManager;' "$CONTROLLER" || {
    echo "ERROR: PageController does not import INavigationManager" >&2
    exit 1
}
grep -Fq 'private INavigationManager $navigationManager' "$CONTROLLER" || {
    echo "ERROR: PageController does not inject INavigationManager" >&2
    exit 1
}
grep -Fq '$c->query(INavigationManager::class)' "$APPLICATION" || {
    echo "ERROR: Application does not supply INavigationManager to PageController" >&2
    exit 1
}

printf '==> PHP syntax validation\n'
while IFS= read -r -d '' php_file; do
    php -l "$php_file" >/dev/null
done < <(find "$APP" -type f -name '*.php' -print0)

printf '==> Compatibility checks passed\n'
