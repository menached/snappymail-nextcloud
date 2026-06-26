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
TEST_PASSWORD="Runtime-Test-Password-33"

cleanup() {
    local rc=$?
    trap - EXIT

    if (( rc != 0 )); then
        echo
        echo "============================================================"
        echo "NEXTCLOUD CONTAINER LOG"
        echo "============================================================"
        docker logs "$NC_CONTAINER" 2>&1 || true

        echo
        echo "============================================================"
        echo "NEXTCLOUD APPLICATION LOG"
        echo "============================================================"
        docker exec "$NC_CONTAINER" sh -lc \
            'test ! -f /var/www/html/data/nextcloud.log || tail -n 250 /var/www/html/data/nextcloud.log' \
            2>&1 || true
    fi

    docker rm -f "$NC_CONTAINER" "$DB_CONTAINER" >/dev/null 2>&1 || true
    docker network rm "$NETWORK" >/dev/null 2>&1 || true
    exit "$rc"
}
trap cleanup EXIT

[[ -f "$APP_DIR/appinfo/info.xml" ]] || {
    echo "ERROR: Built app not found at $APP_DIR" >&2
    exit 1
}
[[ -f "$APP_DIR/app/index.php" ]] || {
    echo "ERROR: Built app is missing app/index.php" >&2
    exit 1
}

echo "============================================================"
echo "START DISPOSABLE NEXTCLOUD 33 ENVIRONMENT"
echo "============================================================"

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

echo
echo "============================================================"
echo "INSTALL NEXTCLOUD"
echo "============================================================"

docker exec -u www-data "$NC_CONTAINER" php occ maintenance:install \
    --database=mysql \
    --database-host="$DB_CONTAINER" \
    --database-name=nextcloud \
    --database-user=nextcloud \
    --database-pass="$DB_PASSWORD" \
    --admin-user=admin \
    --admin-pass='runtime-admin-password'

docker exec -u www-data "$NC_CONTAINER" php occ status

echo
echo "============================================================"
echo "INSTALL PATCHED SNAPPYMAIL APP"
echo "============================================================"

docker exec "$NC_CONTAINER" rm -rf /var/www/html/custom_apps/snappymail
docker cp "$APP_DIR" "$NC_CONTAINER:/var/www/html/custom_apps/snappymail"
docker exec "$NC_CONTAINER" chown -R www-data:www-data \
    /var/www/html/custom_apps/snappymail

docker exec -u www-data "$NC_CONTAINER" php occ app:enable snappymail
docker exec -u www-data "$NC_CONTAINER" php occ app:list | grep -A5 -B2 snappymail

echo
echo "============================================================"
echo "CREATE TEST USER AND ENABLE EMAIL AUTO-LOGIN"
echo "============================================================"

docker exec -u www-data -e OC_PASS="$TEST_PASSWORD" "$NC_CONTAINER" \
    php occ user:add --password-from-env --display-name='SnappyMail Runtime Test' smtest

docker exec -u www-data "$NC_CONTAINER" \
    php occ user:setting smtest settings email smtest@example.net

docker exec -u www-data "$NC_CONTAINER" \
    php occ config:app:set snappymail snappymail-autologin-with-email --value=1

echo
echo "============================================================"
echo "REQUEST AUTHENTICATED SNAPPYMAIL ROUTE"
echo "============================================================"

HTTP_STATUS="$(docker exec "$NC_CONTAINER" curl \
    --silent \
    --show-error \
    --user "smtest:$TEST_PASSWORD" \
    --output /tmp/snappymail-response.html \
    --write-out '%{http_code}' \
    http://127.0.0.1/index.php/apps/snappymail/)"

printf 'HTTP status: %s\n' "$HTTP_STATUS"
if [[ "$HTTP_STATUS" != "200" ]]; then
    docker exec "$NC_CONTAINER" sed -n '1,160p' /tmp/snappymail-response.html || true
    echo "ERROR: Authenticated SnappyMail route did not return HTTP 200" >&2
    exit 1
fi

if docker exec "$NC_CONTAINER" grep -Fqi 'Internal Server Error' \
    /tmp/snappymail-response.html; then
    echo "ERROR: SnappyMail route returned an internal-server-error page" >&2
    exit 1
fi

echo
echo "============================================================"
echo "CHECK FOR KNOWN NC33 FAILURES"
echo "============================================================"

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
    "find /var/www/html/data/appdata_snappymail -type d -path '*/plugins/nextcloud' -print -quit | grep -q ."; then
    echo "ERROR: SnappyMail nextcloud plugin was not installed" >&2
    exit 1
fi

echo
echo "============================================================"
echo "RUNTIME TEST PASSED"
echo "============================================================"
