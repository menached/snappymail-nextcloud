#!/usr/bin/env bash
set -euo pipefail

EXPECTED_HOST="${EXPECTED_HOST:-cloud.doap.com}"
NC_ROOT="${NC_ROOT:-/mnt/data/websites/cloud.doap.com/public_html}"
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/data/backups}"
STANDALONE_PATH="${STANDALONE_PATH:-/var/www/snappymail}"
PHP_BIN="${PHP_BIN:-php}"
PACKAGE=""
APPLY=0
STAMP="$(date +%Y%m%d-%H%M%S)"
SWITCHED=0
CURRENT_ENABLED=0
APP_DIR=""
APP_PARENT=""
STAGE_ROOT=""
STAGE_APP=""
ROLLBACK_DIR=""
FAILED_DIR=""
BACKUP_FILE=""
OLD_AUTO_EMAIL=""
OLD_AUTO_UID=""
STANDALONE_ID=""
LOG_LINE_START=0

section() {
    printf '\n============================================================\n%s\n============================================================\n' "$1"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage:
  sudo bash scripts/deploy-production.sh --package /path/to/package.tar.gz
  sudo bash scripts/deploy-production.sh --package /path/to/package.tar.gz --apply

The default mode performs validation and exits without replacing the app.
Production replacement requires the explicit --apply flag.
USAGE
}

run_occ() {
    runuser -u www-data -- "$PHP_BIN" "$NC_ROOT/occ" "$@"
}

restore_app_value() {
    local key="$1"
    local value="$2"

    if [[ -n "$value" ]]; then
        run_occ config:app:set snappymail "$key" --value="$value" >/dev/null || true
    else
        run_occ config:app:delete snappymail "$key" >/dev/null 2>&1 || true
    fi
}

cleanup_and_rollback() {
    local rc=$?
    trap - EXIT

    if (( rc != 0 && APPLY == 1 && SWITCHED == 1 )); then
        section "ROLLBACK"
        echo "Deployment failed after app replacement. Restoring the previous app."

        run_occ app:disable snappymail >/dev/null 2>&1 || true

        if [[ -d "$APP_DIR" ]]; then
            FAILED_DIR="$APP_PARENT/.snappymail-failed-$STAMP"
            mv "$APP_DIR" "$FAILED_DIR" || true
        fi

        if [[ -d "$ROLLBACK_DIR" ]]; then
            mv "$ROLLBACK_DIR" "$APP_DIR" || true
        fi

        restore_app_value snappymail-autologin-with-email "$OLD_AUTO_EMAIL"
        restore_app_value snappymail-autologin "$OLD_AUTO_UID"

        if (( CURRENT_ENABLED == 1 )); then
            run_occ app:enable snappymail >/dev/null 2>&1 || true
        fi

        echo "Rollback app directory: $APP_DIR"
        [[ -n "$FAILED_DIR" ]] && echo "Failed candidate retained at: $FAILED_DIR"
        [[ -n "$BACKUP_FILE" ]] && echo "Backup archive retained at: $BACKUP_FILE"
    fi

    if [[ -n "$STAGE_ROOT" && -d "$STAGE_ROOT" ]]; then
        rm -rf "$STAGE_ROOT"
    fi

    exit "$rc"
}
trap cleanup_and_rollback EXIT

while (( $# > 0 )); do
    case "$1" in
        --package)
            (( $# >= 2 )) || die "--package requires a path"
            PACKAGE="$2"
            shift 2
            ;;
        --apply)
            APPLY=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown argument: $1"
            ;;
    esac
done

[[ -n "$PACKAGE" ]] || {
    usage
    die "A package path is required"
}
[[ $EUID -eq 0 ]] || die "Run this script through one sudo invocation"

PACKAGE="$(realpath "$PACKAGE")"
[[ -f "$PACKAGE" ]] || die "Package not found: $PACKAGE"
[[ -f "$PACKAGE.sha256" ]] || die "Checksum file not found: $PACKAGE.sha256"

section "VERIFY HOST AND PATHS"

HOST_FQDN="$(hostname -f)"
printf 'Host:             %s\n' "$HOST_FQDN"
printf 'Expected host:    %s\n' "$EXPECTED_HOST"
printf 'Nextcloud root:   %s\n' "$NC_ROOT"
printf 'Package:          %s\n' "$PACKAGE"
printf 'Mode:             %s\n' "$([[ $APPLY -eq 1 ]] && echo APPLY || echo PREFLIGHT)"

[[ "$HOST_FQDN" == "$EXPECTED_HOST" ]] || die "Refusing to run on $HOST_FQDN"
[[ -f "$NC_ROOT/occ" ]] || die "Nextcloud occ not found at $NC_ROOT/occ"
[[ -d "$BACKUP_ROOT" ]] || mkdir -p "$BACKUP_ROOT"
[[ -d "$STANDALONE_PATH" ]] || die "Standalone SnappyMail path is missing: $STANDALONE_PATH"
STANDALONE_ID="$(stat -c '%d:%i' "$STANDALONE_PATH")"

mapfile -t APP_MATCHES < <(
    for base in "$NC_ROOT/apps" "$NC_ROOT/custom_apps"; do
        [[ -d "$base/snappymail" ]] && printf '%s\n' "$base/snappymail"
    done
)

(( ${#APP_MATCHES[@]} == 1 )) || {
    printf 'Discovered app paths:\n'
    printf '  %s\n' "${APP_MATCHES[@]:-none}"
    die "Expected exactly one installed Nextcloud SnappyMail app"
}

APP_DIR="${APP_MATCHES[0]}"
APP_PARENT="$(dirname "$APP_DIR")"
ROLLBACK_DIR="$APP_PARENT/.snappymail-rollback-$STAMP"
STAGE_ROOT="$APP_PARENT/.snappymail-stage-$STAMP"
STAGE_APP="$STAGE_ROOT/snappymail"
BACKUP_FILE="$BACKUP_ROOT/snappymail-nextcloud-before-nc33-$STAMP.tar.gz"

[[ "$APP_DIR" == "$NC_ROOT"/*/snappymail ]] || die "Unexpected application path: $APP_DIR"
[[ ! -e "$ROLLBACK_DIR" ]] || die "Rollback path already exists: $ROLLBACK_DIR"
[[ ! -e "$STAGE_ROOT" ]] || die "Stage path already exists: $STAGE_ROOT"

printf 'Current app:      %s\n' "$APP_DIR"
printf 'Backup archive:   %s\n' "$BACKUP_FILE"
printf 'Standalone inode: %s\n' "$STANDALONE_ID"

section "VERIFY PACKAGE CHECKSUM AND CONTENTS"

EXPECTED_SHA="$(awk 'NR == 1 { print $1 }' "$PACKAGE.sha256")"
ACTUAL_SHA="$(sha256sum "$PACKAGE" | awk '{ print $1 }')"
printf 'Expected SHA256: %s\n' "$EXPECTED_SHA"
printf 'Actual SHA256:   %s\n' "$ACTUAL_SHA"
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || die "Package SHA256 mismatch"

while IFS= read -r path; do
    [[ "$path" == snappymail || "$path" == snappymail/* ]] || die "Unexpected archive path: $path"
    [[ "$path" != /* && "$path" != *'/../'* && "$path" != '../'* ]] || die "Unsafe archive path: $path"
done < <(tar -tzf "$PACKAGE")

mkdir -p "$STAGE_ROOT"
tar -xzf "$PACKAGE" -C "$STAGE_ROOT"

for required in \
    "$STAGE_APP/appinfo/info.xml" \
    "$STAGE_APP/app/index.php" \
    "$STAGE_APP/resources/plugins/nextcloud/index.php"; do
    [[ -f "$required" ]] || die "Candidate is missing $required"
done

grep -Eq '<nextcloud[^>]+max-version="33"' "$STAGE_APP/appinfo/info.xml" || \
    die "Candidate does not declare Nextcloud 33 compatibility"

grep -Fq 'class NextcloudPlugin extends \RainLoop\Plugins\AbstractPlugin' \
    "$STAGE_APP/resources/plugins/nextcloud/index.php" || \
    die "Candidate does not contain the pinned Nextcloud plugin"

section "LINT CANDIDATE"

PHP_COUNT=0
while IFS= read -r -d '' php_file; do
    "$PHP_BIN" -l "$php_file" >/dev/null
    (( PHP_COUNT += 1 ))
done < <(find "$STAGE_APP" -type f -name '*.php' -print0)
printf 'PHP files validated: %d\n' "$PHP_COUNT"

OWNER_UID="$(stat -c '%u' "$APP_DIR")"
OWNER_GID="$(stat -c '%g' "$APP_DIR")"
chown -R "$OWNER_UID:$OWNER_GID" "$STAGE_APP"

if run_occ app:list --enabled | grep -Eq '^[[:space:]]*-[[:space:]]+snappymail:'; then
    CURRENT_ENABLED=1
fi

OLD_AUTO_EMAIL="$(run_occ config:app:get snappymail snappymail-autologin-with-email 2>/dev/null || true)"
OLD_AUTO_UID="$(run_occ config:app:get snappymail snappymail-autologin 2>/dev/null || true)"

printf 'Current enabled:  %s\n' "$CURRENT_ENABLED"
printf 'Old email mode:   %s\n' "${OLD_AUTO_EMAIL:-unset}"
printf 'Old UID mode:     %s\n' "${OLD_AUTO_UID:-unset}"

NEXTCLOUD_LOG="$NC_ROOT/data/nextcloud.log"
if [[ -f "$NEXTCLOUD_LOG" ]]; then
    LOG_LINE_START="$(wc -l < "$NEXTCLOUD_LOG")"
fi

if (( APPLY == 0 )); then
    section "PREFLIGHT COMPLETE"
    echo "PASS: The package, checksum, host, application paths and PHP syntax are valid."
    echo "No production files were replaced. Re-run with --apply only after the production login test is authorized."
    exit 0
fi

section "BACK UP CURRENT APP"

tar -C "$APP_PARENT" -czf "$BACKUP_FILE" "$(basename "$APP_DIR")"
tar -tzf "$BACKUP_FILE" >/dev/null
printf 'Backup validated: %s\n' "$BACKUP_FILE"

section "ATOMIC APP REPLACEMENT"

if (( CURRENT_ENABLED == 1 )); then
    run_occ app:disable snappymail
fi

mv "$APP_DIR" "$ROLLBACK_DIR"
mv "$STAGE_APP" "$APP_DIR"
SWITCHED=1

run_occ app:enable snappymail
run_occ config:app:set snappymail snappymail-autologin-with-email --value=1
run_occ config:app:set snappymail snappymail-autologin --value=0

section "VERIFY DEPLOYED APP"

run_occ status
run_occ app:list --enabled | grep -A3 -B2 snappymail
[[ "$(run_occ config:app:get snappymail snappymail-autologin-with-email)" == "1" ]] || \
    die "Email auto-login was not enabled"

if [[ -f "$NEXTCLOUD_LOG" ]]; then
    NEW_LOG="$STAGE_ROOT/new-nextcloud-log.txt"
    tail -n "+$((LOG_LINE_START + 1))" "$NEXTCLOUD_LOG" > "$NEW_LOG" || true
    if grep -Ei 'Invalid plugin class NextcloudPlugin|OCA\\SnappyMail.*(Exception|Error)|snappymail.*(fatal|exception)' "$NEW_LOG"; then
        die "New SnappyMail errors appeared in the Nextcloud log"
    fi
fi

[[ "$(stat -c '%d:%i' "$STANDALONE_PATH")" == "$STANDALONE_ID" ]] || \
    die "Standalone SnappyMail path changed unexpectedly"

rm -rf "$ROLLBACK_DIR"
SWITCHED=0

section "DEPLOYMENT COMPLETE"
echo "PASS: The Nextcloud SnappyMail app was replaced atomically."
echo "PASS: Email-based automatic login is enabled."
echo "PASS: /var/www/snappymail was not replaced."
echo "Backup: $BACKUP_FILE"
echo "Required final check: sign out of Nextcloud, sign back in with a disposable password account, then open Email and test receive, send and logout."
