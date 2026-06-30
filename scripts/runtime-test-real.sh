#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${APP_DIR:-$ROOT/build/snappymail}"
DOVECOT_CONFIG="${DOVECOT_CONFIG:-$ROOT/tests/dovecot-2.4.conf}"
NEXTCLOUD_IMAGE="${NEXTCLOUD_IMAGE:-nextcloud:33-apache}"
MARIADB_IMAGE="${MARIADB_IMAGE:-mariadb:11.4}"
RUN_ID="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$$"
RUN_ID="${RUN_ID//[^a-zA-Z0-9_.-]/-}"
NETWORK="sm-real-$RUN_ID"
DB="sm-real-db-$RUN_ID"
NC="sm-real-nc-$RUN_ID"
DB_ROOT_PASSWORD="runtime-root-password"
DB_PASSWORD="runtime-nextcloud-password"
USER_NAME="smtest"
USER_EMAIL="smtest@nextcloud"
USER_PASSWORD="Runtime-Test-Password-33"
COOKIES="/tmp/nc-browser-cookies.txt"

section() {
    printf '\n============================================================\n%s\n============================================================\n' "$1"
}

dx() {
    docker exec "$NC" "$@"
}

occ() {
    docker exec -u www-data "$NC" php occ "$@"
}

cleanup() {
    local rc=$?
    trap - EXIT

    if (( rc != 0 )); then
        section "FAILURE DIAGNOSTICS"
        docker logs "$NC" 2>&1 || true
        dx sh -lc 'test ! -f /var/www/html/data/nextcloud.log || tail -n 250 /var/www/html/data/nextcloud.log' 2>&1 || true
        dx sh -lc 'for f in /tmp/dovecot.log /tmp/dovecot-info.log /tmp/dovecot-debug.log; do test ! -f "$f" || { echo "--- $f"; tail -n 250 "$f"; }; done' 2>&1 || true
        dx sh -lc 'for f in /tmp/login-headers /tmp/snappymail-headers /tmp/logout-headers /tmp/cookies-before-logout; do test ! -f "$f" || { echo "--- $f"; cat "$f"; }; done' 2>&1 || true
    fi

    docker rm -f "$NC" "$DB" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    exit "$rc"
}
trap cleanup EXIT

request_token() {
    local file="$1"
    dx php -r '
        $html = file_get_contents($argv[1]);
        if (!preg_match("~data-requesttoken=\"([^\"]+)\"~", $html, $m)) {
            fwrite(STDERR, "request token not found\n");
            exit(1);
        }
        echo html_entity_decode($m[1], ENT_QUOTES | ENT_HTML5);
    ' "$file"
}

assert_cookie() {
    local name="$1"
    dx awk -v name="$name" '$6 == name { found = 1 } END { exit !found }' "$COOKIES" || {
        dx cat "$COOKIES" || true
        echo "ERROR: Cookie $name is missing" >&2
        exit 1
    }
}

assert_no_cookie() {
    local name="$1"
    if dx awk -v name="$name" '$6 == name { found = 1 } END { exit !found }' "$COOKIES"; then
        dx cat "$COOKIES" || true
        echo "ERROR: Cookie $name remained after logout" >&2
        exit 1
    fi
}

[[ -f "$APP_DIR/appinfo/info.xml" ]] || {
    echo "ERROR: Built app not found at $APP_DIR" >&2
    exit 1
}
[[ -f "$DOVECOT_CONFIG" ]] || {
    echo "ERROR: Dovecot fixture not found at $DOVECOT_CONFIG" >&2
    exit 1
}

section "START NEXTCLOUD 33 AND MARIADB"
docker network create "$NETWORK" >/dev/null

docker run -d --name "$DB" --network "$NETWORK" \
    -e MARIADB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" \
    -e MARIADB_DATABASE=nextcloud \
    -e MARIADB_USER=nextcloud \
    -e MARIADB_PASSWORD="$DB_PASSWORD" \
    "$MARIADB_IMAGE" \
    --transaction-isolation=READ-COMMITTED \
    --binlog-format=ROW >/dev/null

for n in $(seq 1 60); do
    docker exec "$DB" mariadb-admin ping -h 127.0.0.1 -uroot \
        -p"$DB_ROOT_PASSWORD" --silent >/dev/null 2>&1 && break
    (( n < 60 )) || {
        echo "ERROR: MariaDB did not become ready" >&2
        exit 1
    }
    sleep 2
done

docker run -d --name "$NC" --network "$NETWORK" \
    -e NEXTCLOUD_TRUSTED_DOMAINS='localhost 127.0.0.1' \
    "$NEXTCLOUD_IMAGE" >/dev/null

for n in $(seq 1 60); do
    dx curl -fsS http://127.0.0.1/status.php >/dev/null 2>&1 && break
    (( n < 60 )) || {
        echo "ERROR: Nextcloud Apache did not become ready" >&2
        exit 1
    }
    sleep 2
done

section "INSTALL NEXTCLOUD AND SNAPPYMAIL"
occ maintenance:install \
    --database=mysql \
    --database-host="$DB" \
    --database-name=nextcloud \
    --database-user=nextcloud \
    --database-pass="$DB_PASSWORD" \
    --admin-user=admin \
    --admin-pass='runtime-admin-password'

dx rm -rf /var/www/html/custom_apps/snappymail
docker cp "$APP_DIR" "$NC:/var/www/html/custom_apps/snappymail"
dx chown -R www-data:www-data /var/www/html/custom_apps/snappymail
occ app:enable snappymail
occ app:list --enabled | grep -F snappymail

section "CREATE PASSWORD USER AND LOCAL IMAP ACCOUNT"
docker exec -u www-data -e OC_PASS="$USER_PASSWORD" "$NC" php occ user:add \
    --password-from-env --display-name='SnappyMail Runtime Test' "$USER_NAME"
occ user:setting "$USER_NAME" settings email "$USER_EMAIL"
occ config:app:set snappymail snappymail-autologin-with-email --value=1


dx sh -lc '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends dovecot-core dovecot-imapd
    rm -rf /var/lib/apt/lists/*
'

docker cp "$DOVECOT_CONFIG" "$NC:/etc/dovecot/dovecot.conf"
WEB_UID="$(dx id -u www-data)"
WEB_GID="$(dx id -g www-data)"
printf '%s:{PLAIN}%s:%s:%s::/tmp/dovecot-mail/%s::\n' \
    "$USER_NAME" "$USER_PASSWORD" "$WEB_UID" "$WEB_GID" "$USER_NAME" | \
    docker exec -i "$NC" sh -c 'cat > /etc/dovecot/users && chown root:dovecot /etc/dovecot/users && chmod 640 /etc/dovecot/users'

dx sh -lc "install -d -o www-data -g www-data /tmp/dovecot-mail/$USER_NAME/Maildir/cur /tmp/dovecot-mail/$USER_NAME/Maildir/new /tmp/dovecot-mail/$USER_NAME/Maildir/tmp"
dx doveconf -c /etc/dovecot/dovecot.conf -n
dx dovecot -c /etc/dovecot/dovecot.conf

for n in $(seq 1 30); do
    dx doveadm -c /etc/dovecot/dovecot.conf auth test "$USER_NAME" "$USER_PASSWORD" >/dev/null 2>&1 && break
    (( n < 30 )) || {
        echo "ERROR: Dovecot authentication did not become ready" >&2
        exit 1
    }
    sleep 1
done

dx doveadm -c /etc/dovecot/dovecot.conf auth test "$USER_NAME" "$USER_PASSWORD"

section "PERFORM REAL NEXTCLOUD BROWSER LOGIN"
dx rm -f "$COOKIES" /tmp/login.html /tmp/after-login.html /tmp/login-headers

dx curl -fsS -c "$COOKIES" -o /tmp/login.html \
    http://127.0.0.1/index.php/login
LOGIN_TOKEN="$(request_token /tmp/login.html)"

LOGIN_HTTP="$(dx curl -sS -L \
    -D /tmp/login-headers \
    -b "$COOKIES" -c "$COOKIES" \
    -H 'Origin: http://127.0.0.1' \
    --data-urlencode "user=$USER_NAME" \
    --data-urlencode "password=$USER_PASSWORD" \
    --data-urlencode "requesttoken=$LOGIN_TOKEN" \
    --data-urlencode 'timezone=UTC' \
    --data-urlencode 'timezone_offset=0' \
    -o /tmp/after-login.html -w '%{http_code}' \
    http://127.0.0.1/index.php/login)"
[[ "$LOGIN_HTTP" == 200 ]] || {
    echo "ERROR: Browser login returned HTTP $LOGIN_HTTP" >&2
    exit 1
}

USER_HTTP="$(dx curl -sS -b "$COOKIES" -H 'OCS-APIRequest: true' \
    -o /tmp/ocs-user.json -w '%{http_code}' \
    'http://127.0.0.1/ocs/v2.php/cloud/user?format=json')"
[[ "$USER_HTTP" == 200 ]] || {
    dx cat /tmp/ocs-user.json || true
    echo "ERROR: Browser session is not authenticated" >&2
    exit 1
}
dx grep -Fq '"id":"smtest"' /tmp/ocs-user.json

section "VERIFY SNAPPYMAIL AUTOMATIC IMAP LOGIN"
SM_HTTP="$(dx curl -sS -L \
    -D /tmp/snappymail-headers \
    -b "$COOKIES" -c "$COOKIES" \
    -o /tmp/snappymail.html -w '%{http_code}' \
    http://127.0.0.1/index.php/apps/snappymail/)"
[[ "$SM_HTTP" == 200 ]] || {
    echo "ERROR: SnappyMail returned HTTP $SM_HTTP" >&2
    exit 1
}
! dx grep -Fqi 'Internal Server Error' /tmp/snappymail.html
assert_cookie smaccount
assert_cookie smsession
dx cp "$COOKIES" /tmp/cookies-before-logout

for n in $(seq 1 20); do
    dx grep -Fq "Login: user=<$USER_NAME>" /tmp/dovecot-info.log 2>/dev/null && break
    (( n < 20 )) || {
        dx cat /tmp/dovecot-info.log || true
        echo "ERROR: No successful IMAP login for $USER_NAME" >&2
        exit 1
    }
    sleep 1
done

dx grep -F "Login: user=<$USER_NAME>" /tmp/dovecot-info.log

KNOWN="$(dx sh -lc 'grep -RInE "Invalid plugin class NextcloudPlugin|Call to undefined method OC\\\\Server|ArgumentCountError|Too few arguments to function OCA\\\\SnappyMail" /var/www/html/data 2>/dev/null || true')"
[[ -z "$KNOWN" ]] || {
    printf '%s\n' "$KNOWN"
    echo "ERROR: Known Nextcloud 33 compatibility failure found" >&2
    exit 1
}

dx sh -lc "find /var/www/html/data/appdata_snappymail -type f -path '*/plugins/nextcloud/index.php' -print -quit | grep -q ."

section "VERIFY LOGOUT SESSION ISOLATION"
LOGOUT_TOKEN="$(request_token /tmp/snappymail.html)"
LOGOUT_HTTP="$(dx curl -sS -G \
    -D /tmp/logout-headers \
    -b "$COOKIES" -c "$COOKIES" \
    --data-urlencode "requesttoken=$LOGOUT_TOKEN" \
    -o /tmp/logout.html -w '%{http_code}' \
    http://127.0.0.1/index.php/logout)"
case "$LOGOUT_HTTP" in
    302|303) ;;
    *)
        echo "ERROR: Logout returned HTTP $LOGOUT_HTTP" >&2
        exit 1
        ;;
esac
assert_no_cookie smaccount
assert_no_cookie smsession

POST_LOGOUT_HTTP="$(dx curl -sS -b "$COOKIES" -H 'OCS-APIRequest: true' \
    -o /tmp/ocs-after-logout.json -w '%{http_code}' \
    'http://127.0.0.1/ocs/v2.php/cloud/user?format=json')"
if [[ "$POST_LOGOUT_HTTP" == 200 ]] && dx grep -Fq '"id":"smtest"' /tmp/ocs-after-logout.json; then
    echo "ERROR: Nextcloud session remained authenticated after logout" >&2
    exit 1
fi

section "REAL AUTOMATIC-LOGIN TEST PASSED"
echo "PASS: Nextcloud password login created a SnappyMail IMAP session."
echo "PASS: The pinned Nextcloud plugin loaded on Nextcloud 33."
echo "PASS: Logout cleared Nextcloud and SnappyMail session state."
