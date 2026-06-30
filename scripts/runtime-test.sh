#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${APP_DIR:-$ROOT/build/snappymail}"
NEXTCLOUD_IMAGE="${NEXTCLOUD_IMAGE:-nextcloud:33-apache}"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11.4}"
RUN_TOKEN="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$$"
RUN_TOKEN="${RUN_TOKEN//[^a-zA-Z0-9_.-]/-}"
NETWORK="sm-nc33-${RUN_TOKEN}"
DB_CONTAINER="sm-db-${RUN_TOKEN}"
NC_CONTAINER="sm-nc-${RUN_TOKEN}"
DB_ROOT_PASSWORD="runtime-root-password"
DB_PASSWORD="runtime-nextcloud-password"
TEST_USER="smtest"
TEST_EMAIL="smtest@nextcloud"
TEST_PASSWORD="Runtime-Test-Password-33"
COOKIE_JAR="/tmp/nextcloud-browser-cookies.txt"

section() {
    printf '\n============================================================\n%s\n============================================================\n' "$1"
}

cleanup() {
    local rc=$?
    trap - EXIT

    if (( rc != 0 )); then
        section "NEXTCLOUD CONTAINER LOG"
        docker logs "$NC_CONTAINER" 2>&1 || true

        section "NEXTCLOUD APPLICATION LOG"
        docker exec "$NC_CONTAINER" sh -lc \
            'test ! -f /var/www/html/data/nextcloud.log || tail -n 250 /var/www/html/data/nextcloud.log' \
            2>&1 || true

        section "DOVECOT LOG"
        docker exec "$NC_CONTAINER" sh -lc \
            'for file in /tmp/dovecot.log /tmp/dovecot-info.log /tmp/dovecot-debug.log; do test ! -f "$file" || { echo "--- $file"; tail -n 250 "$file"; }; done' \
            2>&1 || true

        section "RUNTIME RESPONSE HEADERS"
        docker exec "$NC_CONTAINER" sh -lc \
            'for file in /tmp/login-headers.txt /tmp/snappymail-headers.txt /tmp/logout-headers.txt; do test ! -f "$file" || { echo "--- $file"; cat "$file"; }; done' \
            2>&1 || true
    fi

    docker rm -f "$NC_CONTAINER" "$DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    exit "$rc"
}
trap cleanup EXIT

extract_request_token() {
    local html_file="$1"

    docker exec "$NC_CONTAINER" php -r '
        $html = file_get_contents($argv[1]);
        if (!preg_match("~data-requesttoken=\"([^\"]+)\"~", $html, $matches)) {
            fwrite(STDERR, "Unable to find data-requesttoken in {$argv[1]}\n");
            exit(1);
        }
        echo html_entity_decode($matches[1], ENT_QUOTES | ENT_HTML5);
    ' "$html_file"
}

[[ -f "$APP_DIR/appinfo/info.xml" ]] || {
    echo "ERROR: Built app not found at $APP_DIR" >&2
    exit 1
}
[[ -f "$APP_DIR/app/index.php" ]] || {
    echo "ERROR: Built app is missing app/index.php" >&2
    exit 1
}

section "START DISPOSABLE NEXTCLOUD 33 ENVIRONMENT"

docker network create "$NETWORK" >/dev/null

docker run -d \
    --name "$DB_CONTAINER" \
    --network "$NETWORK" \
    -e MARIADB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" \
    -e MARIADB_DATABASE=nextcloud \
    -e MARIADB_USER=nextcloud \
    -e MARIADB_PASSWORD="$DB_PASSWORD" \
    "$MARIADB_IMAGE" \
    --transaction-isolation=READ-COMMITTED \
    --binlog-format=ROW >/dev/null

for attempt in $(seq 1 60); do
    if docker exec "$DB_CONTAINER" mariadb-admin ping \
        --host=127.0.0.1 \
        --user=root \
        --password="$DB_ROOT_PASSWORD" \
        --silent >/dev/null 2>&1; then
        break
    fi

    if (( attempt == 60 )); then
        echo "ERROR: MariaDB did not become ready" >&2
        exit 1
    fi
    sleep 2
done

docker run -d \
    --name "$NC_CONTAINER" \
    --network "$NETWORK" \
    -e NEXTCLOUD_TRUSTED_DOMAINS='localhost 127.0.0.1' \
    "$NEXTCLOUD_IMAGE" >/dev/null

for attempt in $(seq 1 60); do
    if docker exec "$NC_CONTAINER" curl --fail --silent \
        http://127.0.0.1/status.php >/dev/null 2>&1; then
        break
    fi

    if (( attempt == 60 )); then
        echo "ERROR: Nextcloud Apache did not become ready" >&2
        exit 1
    fi
    sleep 2
done

section "INSTALL NEXTCLOUD"

docker exec -u www-data "$NC_CONTAINER" php occ maintenance:install \
    --database=mysql \
    --database-host="$DB_CONTAINER" \
    --database-name=nextcloud \
    --database-user=nextcloud \
    --database-pass="$DB_PASSWORD" \
    --admin-user=admin \
    --admin-pass='runtime-admin-password'

docker exec -u www-data "$NC_CONTAINER" php occ status

section "INSTALL PATCHED SNAPPYMAIL APP"

docker exec "$NC_CONTAINER" rm -rf /var/www/html/custom_apps/snappymail
docker cp "$APP_DIR" "$NC_CONTAINER:/var/www/html/custom_apps/snappymail"
docker exec "$NC_CONTAINER" chown -R www-data:www-data \
    /var/www/html/custom_apps/snappymail

docker exec -u www-data "$NC_CONTAINER" php occ app:enable snappymail
docker exec -u www-data "$NC_CONTAINER" php occ app:list | grep -A5 -B2 snappymail

section "CREATE TEST USER AND ENABLE EMAIL AUTO-LOGIN"

docker exec -u www-data -e OC_PASS="$TEST_PASSWORD" "$NC_CONTAINER" \
    php occ user:add --password-from-env --display-name='SnappyMail Runtime Test' "$TEST_USER"

docker exec -u www-data "$NC_CONTAINER" \
    php occ user:setting "$TEST_USER" settings email "$TEST_EMAIL"

docker exec -u www-data "$NC_CONTAINER" \
    php occ config:app:set snappymail snappymail-autologin-with-email --value=1

docker exec -u www-data "$NC_CONTAINER" \
    php occ config:app:get snappymail snappymail-autologin-with-email | grep -Fx 1

section "INSTALL DISPOSABLE LOCAL IMAP SERVER"

docker exec -e DEBIAN_FRONTEND=noninteractive "$NC_CONTAINER" sh -lc '
    set -eu
    apt-get update
    apt-get install -y --no-install-recommends dovecot-core dovecot-imapd
    rm -rf /var/lib/apt/lists/*
'

WEB_UID="$(docker exec "$NC_CONTAINER" id -u www-data)"
WEB_GID="$(docker exec "$NC_CONTAINER" id -g www-data)"

docker exec -i "$NC_CONTAINER" sh -c 'cat > /etc/dovecot/dovecot.conf' <<DOVECOT
protocols = imap
listen = 127.0.0.1
ssl = no
disable_plaintext_auth = no
auth_mechanisms = plain login
mail_location = maildir:/tmp/dovecot-mail/%n/Maildir
first_valid_uid = 1
first_valid_gid = 1

passdb {
  driver = passwd-file
  args = scheme=PLAIN username_format=%n /etc/dovecot/users
}

userdb {
  driver = static
  args = uid=${WEB_UID} gid=${WEB_GID} home=/tmp/dovecot-mail/%n
}

namespace inbox {
  inbox = yes
}

service imap-login {
  inet_listener imap {
    address = 127.0.0.1
    port = 143
  }
}

log_path = /tmp/dovecot.log
info_log_path = /tmp/dovecot-info.log
debug_log_path = /tmp/dovecot-debug.log
auth_verbose = yes
DOVECOT

printf '%s:{PLAIN}%s\n' "$TEST_USER" "$TEST_PASSWORD" | \
    docker exec -i "$NC_CONTAINER" sh -c 'cat > /etc/dovecot/users && chmod 600 /etc/dovecot/users'

docker exec -u www-data "$NC_CONTAINER" sh -lc \
    "mkdir -p /tmp/dovecot-mail/$TEST_USER/Maildir/cur /tmp/dovecot-mail/$TEST_USER/Maildir/new /tmp/dovecot-mail/$TEST_USER/Maildir/tmp"

docker exec "$NC_CONTAINER" dovecot -c /etc/dovecot/dovecot.conf

for attempt in $(seq 1 30); do
    if docker exec "$NC_CONTAINER" doveadm -c /etc/dovecot/dovecot.conf \
        auth test "$TEST_USER" "$TEST_PASSWORD" >/dev/null 2>&1; then
        break
    fi

    if (( attempt == 30 )); then
        echo "ERROR: Disposable Dovecot authentication did not become ready" >&2
        exit 1
    fi
    sleep 1
done

docker exec "$NC_CONTAINER" doveadm -c /etc/dovecot/dovecot.conf \
    auth test "$TEST_USER" "$TEST_PASSWORD"

section "PERFORM REAL NEXTCLOUD BROWSER LOGIN"

docker exec "$NC_CONTAINER" rm -f \
    "$COOKIE_JAR" \
    /tmp/nc-login.html \
    /tmp/nc-after-login.html \
    /tmp/login-headers.txt

docker exec "$NC_CONTAINER" curl \
    --silent \
    --show-error \
    --cookie-jar "$COOKIE_JAR" \
    --output /tmp/nc-login.html \
    http://127.0.0.1/index.php/login

LOGIN_TOKEN="$(extract_request_token /tmp/nc-login.html)"
[[ -n "$LOGIN_TOKEN" ]] || {
    echo "ERROR: Empty Nextcloud login request token" >&2
    exit 1
}

LOGIN_STATUS="$(docker exec "$NC_CONTAINER" curl \
    --silent \
    --show-error \
    --location \
    --dump-header /tmp/login-headers.txt \
    --cookie "$COOKIE_JAR" \
    --cookie-jar "$COOKIE_JAR" \
    --header 'Origin: http://127.0.0.1' \
    --data-urlencode "user=$TEST_USER" \
    --data-urlencode "password=$TEST_PASSWORD" \
    --data-urlencode "requesttoken=$LOGIN_TOKEN" \
    --data-urlencode 'timezone=UTC' \
    --data-urlencode 'timezone_offset=0' \
    --output /tmp/nc-after-login.html \
    --write-out '%{http_code}' \
    http://127.0.0.1/index.php/login)"

printf 'Nextcloud login final HTTP status: %s\n' "$LOGIN_STATUS"
[[ "$LOGIN_STATUS" == "200" ]] || {
    echo "ERROR: Nextcloud browser login did not finish with HTTP 200" >&2
    exit 1
}

USER_STATUS="$(docker exec "$NC_CONTAINER" curl \
    --silent \
    --show-error \
    --cookie "$COOKIE_JAR" \
    --header 'OCS-APIRequest: true' \
    --output /tmp/ocs-user.json \
    --write-out '%{http_code}' \
    'http://127.0.0.1/ocs/v2.php/cloud/user?format=json')"

printf 'Authenticated OCS user HTTP status: %s\n' "$USER_STATUS"
[[ "$USER_STATUS" == "200" ]] || {
    docker exec "$NC_CONTAINER" cat /tmp/ocs-user.json || true
    echo "ERROR: Browser cookie did not authenticate the Nextcloud user" >&2
    exit 1
}
docker exec "$NC_CONTAINER" grep -Fq '"id":"smtest"' /tmp/ocs-user.json || {
    docker exec "$NC_CONTAINER" cat /tmp/ocs-user.json || true
    echo "ERROR: Authenticated Nextcloud user is not $TEST_USER" >&2
    exit 1
}

section "VERIFY AUTOMATIC SNAPPYMAIL IMAP LOGIN"

SNAPPYMAIL_STATUS="$(docker exec "$NC_CONTAINER" curl \
    --silent \
    --show-error \
    --location \
    --dump-header /tmp/snappymail-headers.txt \
    --cookie "$COOKIE_JAR" \
    --cookie-jar "$COOKIE_JAR" \
    --output /tmp/snappymail-response.html \
    --write-out '%{http_code}' \
    http://127.0.0.1/index.php/apps/snappymail/)"

printf 'SnappyMail HTTP status: %s\n' "$SNAPPYMAIL_STATUS"
[[ "$SNAPPYMAIL_STATUS" == "200" ]] || {
    docker exec "$NC_CONTAINER" sed -n '1,160p' /tmp/snappymail-response.html || true
    echo "ERROR: Authenticated SnappyMail route did not return HTTP 200" >&2
    exit 1
}

if docker exec "$NC_CONTAINER" grep -Fqi 'Internal Server Error' \
    /tmp/snappymail-response.html; then
    echo "ERROR: SnappyMail route returned an internal-server-error page" >&2
    exit 1
fi

for cookie_name in smaccount smsession; do
    if ! docker exec "$NC_CONTAINER" awk -v name="$cookie_name" '$6 == name { found = 1 } END { exit !found }' "$COOKIE_JAR"; then
        docker exec "$NC_CONTAINER" cat "$COOKIE_JAR" || true
        echo "ERROR: Automatic login did not create the $cookie_name cookie" >&2
        exit 1
    fi
done

for attempt in $(seq 1 20); do
    if docker exec "$NC_CONTAINER" grep -Fq "Login: user=<$TEST_USER>" /tmp/dovecot-info.log 2>/dev/null; then
        break
    fi

    if (( attempt == 20 )); then
        docker exec "$NC_CONTAINER" cat /tmp/dovecot-info.log || true
        echo "ERROR: Dovecot did not record an IMAP login for $TEST_USER" >&2
        exit 1
    fi
    sleep 1
done

docker exec "$NC_CONTAINER" grep -F "Login: user=<$TEST_USER>" /tmp/dovecot-info.log

section "CHECK FOR KNOWN NEXTCLOUD 33 FAILURES"

KNOWN_FAILURES="$(docker exec "$NC_CONTAINER" sh -lc '
    grep -RInE \
        "Invalid plugin class NextcloudPlugin|Call to undefined method OC\\\\Server|ArgumentCountError|Too few arguments to function OCA\\\\SnappyMail" \
        /var/www/html/data 2>/dev/null || true
')"

if [[ -n "$KNOWN_FAILURES" ]]; then
    printf '%s\n' "$KNOWN_FAILURES"
    echo "ERROR: Known SnappyMail/Nextcloud compatibility failure detected" >&2
    exit 1
fi

if ! docker exec "$NC_CONTAINER" sh -lc \
    "find /var/www/html/data/appdata_snappymail -type f -path '*/plugins/nextcloud/index.php' -print -quit | grep -q ."; then
    echo "ERROR: Bundled SnappyMail Nextcloud plugin was not installed" >&2
    exit 1
fi

section "VERIFY LOGOUT AND SESSION ISOLATION"

LOGOUT_TOKEN="$(extract_request_token /tmp/snappymail-response.html)"
[[ -n "$LOGOUT_TOKEN" ]] || {
    echo "ERROR: Empty authenticated logout request token" >&2
    exit 1
}

LOGOUT_STATUS="$(docker exec "$NC_CONTAINER" curl \
    --silent \
    --show-error \
    --get \
    --dump-header /tmp/logout-headers.txt \
    --cookie "$COOKIE_JAR" \
    --cookie-jar "$COOKIE_JAR" \
    --data-urlencode "requesttoken=$LOGOUT_TOKEN" \
    --output /tmp/logout-response.html \
    --write-out '%{http_code}' \
    http://127.0.0.1/index.php/logout)"

printf 'Nextcloud logout HTTP status: %s\n' "$LOGOUT_STATUS"
case "$LOGOUT_STATUS" in
    302|303) ;;
    *)
        echo "ERROR: Nextcloud logout did not return a redirect" >&2
        exit 1
        ;;
esac

for cookie_name in smaccount smsession; do
    if docker exec "$NC_CONTAINER" awk -v name="$cookie_name" '$6 == name { found = 1 } END { exit !found }' "$COOKIE_JAR"; then
        docker exec "$NC_CONTAINER" cat "$COOKIE_JAR" || true
        echo "ERROR: Logout left the $cookie_name cookie active" >&2
        exit 1
    fi
done

POST_LOGOUT_STATUS="$(docker exec "$NC_CONTAINER" curl \
    --silent \
    --show-error \
    --cookie "$COOKIE_JAR" \
    --header 'OCS-APIRequest: true' \
    --output /tmp/ocs-user-after-logout.json \
    --write-out '%{http_code}' \
    'http://127.0.0.1/ocs/v2.php/cloud/user?format=json')"

printf 'Post-logout OCS user HTTP status: %s\n' "$POST_LOGOUT_STATUS"
if [[ "$POST_LOGOUT_STATUS" == "200" ]] && \
   docker exec "$NC_CONTAINER" grep -Fq '"id":"smtest"' /tmp/ocs-user-after-logout.json; then
    docker exec "$NC_CONTAINER" cat /tmp/ocs-user-after-logout.json || true
    echo "ERROR: Nextcloud session remained authenticated after logout" >&2
    exit 1
fi

section "RUNTIME TEST PASSED"
echo "PASS: Nextcloud browser password login created an automatic SnappyMail IMAP session."
echo "PASS: The pinned bundled Nextcloud plugin loaded without known NC33 failures."
echo "PASS: Nextcloud logout cleared both the Nextcloud and SnappyMail sessions."
