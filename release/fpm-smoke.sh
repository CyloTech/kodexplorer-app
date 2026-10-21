#!/bin/sh
# Runs inside the image as root, with no network. Sets the container up the
# way a new Kodbox instance's first boot does (the base image's
# /scripts/nginx_php7.sh, then Kodbox's kod.sh), starts nginx and php-fpm8.3
# with that production configuration, and checks that:
#   - nginx -t and php-fpm8.3 -t pass on the generated configuration;
#   - kod.sh installs Kodbox and the Kodbox page is served through php-fpm;
#   - a PHP page reports the FPM SAPI;
#   - a multipart/form-data upload is parsed into $_POST and $_FILES.
set -eu

fail() {
    echo "fpm smoke: $*" >&2
    for log in /tmp/fpm-smoke-kod.log /home/appbox/logs/php8.3-fpm.log /home/appbox/logs/nginx/error.log; do
        [ -f "$log" ] && { echo "--- $log" >&2; tail -20 "$log" >&2; }
    done
    exit 1
}

: "${INST_SCRIPTS:?image has no INST_SCRIPTS}"
: "${HTTP_DOMAIN:?image has no HTTP_DOMAIN}"
# Throwaway administrator password for this test container only. Kodbox
# requires at least three of: digits, upper case, lower case, symbols.
ADMIN_PASS="Kb$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')Z9"
export ADMIN_PASS

# What 20_installer.sh and 30_installer.sh do before kod.sh.
mkdir -p /home/appbox/config /home/appbox/logs /home/appbox/data /run/php
chown -R appbox:appbox /run/php
/bin/bash /scripts/nginx_php7.sh >/tmp/fpm-smoke-nginx-php7.log 2>&1 || fail "nginx_php7.sh failed"
chown -R appbox:appbox /home/appbox/config /home/appbox/logs /home/appbox/public_html

nginx -t -c /home/appbox/config/nginx/nginx.conf || fail "nginx -t failed on the generated configuration"
php-fpm8.3 -t --fpm-config /home/appbox/config/php-fpm/php-fpm.conf \
    || fail "php-fpm8.3 -t failed on the generated configuration"

# kod.sh starts php-fpm and nginx, copies Kodbox into public_html, runs the
# Kodbox installer over HTTP and stops both servers again.
timeout 300 /bin/bash "$INST_SCRIPTS/kod.sh" >/tmp/fpm-smoke-kod.log 2>&1 || fail "kod.sh failed or timed out"
[ -f /home/appbox/public_html/index.php ] || fail "kod.sh did not install Kodbox into public_html"
[ -d /home/appbox/data/system ] || fail "kod.sh did not create /home/appbox/data/system"
# kod.sh posts the database step and the administrator step to the Kodbox
# installer; both must answer "code": true.
installer_ok=$(grep -c '"code": true' /tmp/fpm-smoke-kod.log || true)
[ "$installer_ok" -ge 2 ] || fail "the Kodbox installer did not accept both install steps ($installer_ok of 2)"
if grep -q '"code": false' /tmp/fpm-smoke-kod.log; then
    fail "the Kodbox installer rejected an install step"
fi
[ -f /home/appbox/data/system/install.lock ] || fail "Kodbox did not write install.lock"
[ -f /home/appbox/public_html/config/setting_user.php ] || fail "Kodbox did not write config/setting_user.php"
echo "kod.sh installed Kodbox (database and administrator steps accepted)"
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x nginx >/dev/null 2>&1 || pgrep -f php-fpm >/dev/null 2>&1 || break
    sleep 1
done

# Start the servers as the runit services do.
php-fpm8.3 --fpm-config /home/appbox/config/php-fpm/php-fpm.conf || fail "php-fpm8.3 did not start"
nginx -c /home/appbox/config/nginx/nginx.conf || fail "nginx did not start"

ready=
for attempt in $(seq 1 40); do
    if curl -s -o /dev/null http://127.0.0.1/; then ready=1; break; fi
    sleep 0.5
done
[ -n "$ready" ] || fail "nginx did not answer on port 80"

kodbox_status=$(curl -s -L -o /tmp/fpm-smoke-index.html -w '%{http_code}' http://127.0.0.1/)
[ "$kodbox_status" = 200 ] || fail "Kodbox page returned HTTP $kodbox_status"
grep -qi kodbox /tmp/fpm-smoke-index.html || fail "Kodbox page does not mention Kodbox"
if grep -qi 'install/index' /tmp/fpm-smoke-index.html; then
    fail "Kodbox serves its installer, so kod.sh did not finish the install"
fi
echo "Kodbox page served (HTTP 200)"

mkdir -p /home/appbox/public_html/fpm-smoke
cat > /home/appbox/public_html/fpm-smoke/info.php <<'PHP'
<?php
echo PHP_SAPI, ' ', PHP_VERSION;
PHP
cat > /home/appbox/public_html/fpm-smoke/upload.php <<'PHP'
<?php
$f = isset($_FILES['f']) ? $_FILES['f'] : null;
$hash = ($f && $f['error'] === UPLOAD_ERR_OK && is_uploaded_file($f['tmp_name']))
    ? hash_file('sha256', $f['tmp_name']) : '-';
echo count($_FILES), ':', $f ? $f['size'] : -1, ':', $f ? $f['error'] : -1, ':', $hash, ':',
    isset($_POST['a']) ? $_POST['a'] : '';
PHP
chown -R appbox:appbox /home/appbox/public_html/fpm-smoke

info=$(curl -s http://127.0.0.1/fpm-smoke/info.php)
case "$info" in
    "fpm-fcgi 8.3."*) echo "PHP page served by php-fpm: $info" ;;
    *) fail "PHP page returned '$info', expected 'fpm-fcgi 8.3.x'" ;;
esac

head -c 200000 /dev/urandom > /tmp/fpm-smoke-upload.bin
upload_size=$(wc -c < /tmp/fpm-smoke-upload.bin | tr -d ' ')
upload_hash=$(sha256sum /tmp/fpm-smoke-upload.bin | awk '{print $1}')
result=$(curl -s -F a=b -F f=@/tmp/fpm-smoke-upload.bin http://127.0.0.1/fpm-smoke/upload.php)
expected="1:$upload_size:0:$upload_hash:b"
[ "$result" = "$expected" ] || fail "multipart upload through php-fpm returned '$result', expected '$expected'"
echo "multipart upload through nginx and php-fpm parsed ($upload_size bytes, sha256 matches)"
