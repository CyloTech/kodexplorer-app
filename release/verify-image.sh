#!/bin/bash
# Release gate for Kodbox 1.70.03: the deployed kodbox:1.70.02-2 image with
# Kodbox 1.70.03 (CyloTech/kodbox appbox-1.70.03) in /kod_sources.
#
# Usage: release/verify-image.sh <registry>/<repository>:<tag>
#
# Runs on the builder, next to Docker. Every check reports PASS or FAIL; the
# script exits 0 only when all of them passed and the authenticated registry
# definitively reports that the tag does not exist yet. Any indeterminate
# registry answer fails.
#
# A trial build is tagged under another name (local/kodbox-trial:<tag>). Set
# VERIFY_REGISTRY_REF to the repo.cylo.net reference the release will use and
# the registry check looks that tag up instead of the image reference.
#
# Checks:
#   image    built on the 1.70.02-2 layers; same packages, PHP modules,
#            command and environment; /kod_sources is exactly the files in
#            release/kod_sources-1.70.03.sha256 (Kodbox 1.70.03); the install
#            scripts are the repository's; kod.sh has no tracing and no HTTP
#            install; tests/test-installed-callback.sh passes.
#   fresh    new volumes, dummy ADMIN_PASS with "-", "+", "&", "%", "#", "=":
#            install/index/save requests sent from the moment the container
#            starts are never accepted (nothing listens during the install,
#            Kodbox rejects them afterwards); the administrator logs in with
#            ADMIN_PASS and not with the attacker's password; one installed
#            callback is sent; ADMIN_PASS is not in the container log or in
#            plain text on the volumes.
#   restart  the same container restarts without installing again or sending
#            another callback; the administrator still logs in.
#   weak     an ADMIN_PASS Kodbox refuses stops the first start: the container
#            exits, nothing is served, no callback is marked, install.lock and
#            setting_user.php are absent, and a second start fails the same way.
#   upgrade  run twice, from 1.70.02-1 and from 1.70.02-2: the old image
#            installs on new volumes and gets a second user; the candidate on
#            the same volumes, with a different ADMIN_PASS, runs Kodbox 1.70.03,
#            keeps the database, both users and their passwords, does not
#            install again and sends the installed callback.
#
# Containers run with --network none; each has its own mock installed-callback
# API inside it (APPBOX_CALLBACK_BASE). Every container and volume this script
# creates is named kodbox-gate-<run id>-* and removed on exit.
set -u -o pipefail

# The deployed 1.70.02-2 image (the current default) this release is built FROM.
BASE_IMAGE=repo.cylo.net/kodbox@sha256:60e5b07d8db4e8bafe723c856f374a8c11884fb4c83349f52c2e56293f564d51
# The deployed 1.70.02-1 image, still installed on customer instances; the
# upgrade is tested from it as well.
OLD_IMAGE=repo.cylo.net/kodbox@sha256:8e6cd075d8e360f5b0d8832b077ee315c2fd9544fc795e7be96181c227bd16ed
WEB_TIMEOUT=${GATE_WEB_TIMEOUT:-900}

failures=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
die() { echo "FAIL: $*" >&2; exit 1; }

[ "$#" -eq 1 ] || die "usage: $0 <registry>/<repository>:<tag>"
image_ref=$1
registry_ref=${VERIFY_REGISTRY_REF:-$image_ref}
for ref in "$image_ref" "$registry_ref"; do
    case "$ref" in
        ''|*[!A-Za-z0-9._/:-]*|*@*) die "invalid image reference: $ref" ;;
    esac
done
case "$registry_ref" in
    repo.cylo.net/kodbox:*) ;;
    *) die "registry reference must be repo.cylo.net/kodbox:<tag>: $registry_ref" ;;
esac
release_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(dirname "$release_dir")

run_id=kodbox-gate-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
work_dir=$(mktemp -d)
containers=()
volumes=()
cleanup() {
    local name
    for name in "${containers[@]}"; do docker rm -f "$name" >/dev/null 2>&1; done
    for name in "${volumes[@]}"; do docker volume rm -f "$name" >/dev/null 2>&1; done
    rm -rf "$work_dir"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

docker image inspect "$image_ref" >/dev/null 2>&1 || die "$image_ref is not a local image"
for ref in "$BASE_IMAGE" "$OLD_IMAGE"; do
    docker image inspect "$ref" >/dev/null 2>&1 || docker pull -q "$ref" >/dev/null \
        || die "cannot read the image $ref"
done
[ -s "$release_dir/kod_sources-1.70.03.sha256" ] || die "release/kod_sources-1.70.03.sha256 is missing"

# Dummy credentials for the throwaway test containers only.
fresh_pass='-Gate+Pw&1%2B#Q=z'
attacker_pass='Att4ck3r!Pass'
old_pass='OldGate1!pass'
new_pass='NewGate2!pass'
second_user='gateuser'
second_pass='GateUser3!pass'
weak_pass='password'
callback_id=4242
callback_query_token=gatequerytoken0123
callback_header_token=gateheadertoken0123

# Mock installed-callback API, run inside a test container: answers 200 and
# appends {"path", "token"} per request to the log file.
mock_py='
import http.server, json, sys
port, log = int(sys.argv[1]), sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "token": self.headers.get("X-Cylo-Callback-Token", "")}) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{\"success\":true}")
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
'

# Unauthenticated install requests, sent from inside a test container every
# 0.2 s until /var/log/gate-attack.stop exists or $1 seconds have passed. One
# line per request: "<epoch> <step> <body> HTTP<code>".
attack_sh='
log=/var/log/gate-attack.log
end=$(( $(date +%s) + $1 ))
while [ ! -f /var/log/gate-attack.stop ] && [ "$(date +%s)" -lt "$end" ]; do
    for body in "action=db&dbType=sqlite&pdoType=sqlite&cacheType=file" "action=user&name=admin&password=$2"; do
        out=$(curl -s -m 3 -w " HTTP%{http_code}" -X POST --data "$body" "http://127.0.0.1/?install/index/save" 2>/dev/null | tr -d "\n")
        echo "$(date +%s) ${body%%&*} ${out:- HTTP000}" >> "$log"
    done
    sleep 0.2
done
'

new_volume() {
    docker volume create "$1" >/dev/null || die "cannot create volume $1"
    volumes+=("$1")
}

# start_container <name> <image> <env file> <public_html volume> <data volume>
start_container() {
    containers+=("$1")
    docker run -d --name "$1" --network none --env-file "$3" \
        -v "$4:/home/appbox/public_html" -v "$5:/home/appbox/data" "$2" >/dev/null
}

# write_env <file> <ADMIN_PASS> [HTTP_DOMAIN]
write_env() {
    {
        printf 'ADMIN_PASS=%s\n' "$2"
        printf 'ADMIN_USER=admin\n'
        printf 'HTTP_DOMAIN=%s\n' "${3:-http://kodbox.gate.invalid}"
        printf 'INSTANCE_ID=%s?callback_token=%s\n' "$callback_id" "$callback_query_token"
        printf 'CALLBACK_TOKEN=%s\n' "$callback_header_token"
        printf 'APPBOX_CALLBACK_BASE=http://127.0.0.1:18080\n'
        printf 'APPBOX_CALLBACK_RETRY_DELAY=1\n'
    } > "$1"
}

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

# wait_for_web <container>: 0 once nginx serves the Kodbox page, 1 on timeout,
# 2 if the container stopped.
wait_for_web() {
    local deadline=$(( $(date +%s) + WEB_TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        running "$1" || return 2
        [ "$(docker exec "$1" curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1/ 2>/dev/null)" = 200 ] && return 0
        sleep 3
    done
    return 1
}

# wait_for_exit <container>: 0 once it has stopped, 1 on timeout.
wait_for_exit() {
    local deadline=$(( $(date +%s) + WEB_TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        running "$1" || return 0
        sleep 3
    done
    return 1
}

# wait_for_log <container> <fixed string>
wait_for_log() {
    local deadline=$(( $(date +%s) + WEB_TIMEOUT ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        docker logs "$1" 2>&1 | grep -qF -- "$2" && return 0
        running "$1" || return 2
        sleep 3
    done
    return 1
}

start_mock() { docker exec -d "$1" python3 -c "$mock_py" 18080 /var/log/gate-callback.log; }
callback_requests() { docker exec "$1" sh -c 'cat /var/log/gate-callback.log 2>/dev/null' | grep -c . ; }

# login <container> <name> <password>: prints Kodbox's JSON answer.
login() {
    docker exec "$1" curl -s -m 30 --data-urlencode "name=$2" --data-urlencode "password=$3" \
        'http://127.0.0.1/?user/index/loginSubmit'
}
json_ok() { grep -Eq '"code": ?true'; }

# admin_snapshot <container>: settings DB file and the user rows (id, name,
# role, status, password hash), read with sqlite3 inside the container.
db_snapshot() {
    docker exec "$1" sh -c '
        db=$(sed -n "s/.*USER_SYSTEM\.'"'"'\([A-Za-z0-9]*\.php\)'"'"'.*/\1/p" /home/appbox/public_html/config/setting_user.php | head -1)
        [ -n "$db" ] || exit 1
        echo "db=$db"
        sqlite3 "/home/appbox/data/system/$db" "SELECT userID, name, roleID, status, password FROM user ORDER BY userID;"
        sqlite3 "/home/appbox/data/system/$db" "SELECT COUNT(*) FROM io_source;"'
}

logs_contain_secret() {
    docker logs "$1" 2>&1 | grep -qF -e "$2" -e "$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$2")"
}

echo "== Image"
image_layers=$(docker image inspect -f '{{json .RootFS.Layers}}' "$image_ref")
base_layers=$(docker image inspect -f '{{json .RootFS.Layers}}' "$BASE_IMAGE")
if [ -n "$base_layers" ] && [ "${image_layers#"${base_layers%]}"}" != "$image_layers" ]; then
    pass "built on every layer of the 1.70.02-2 image"
else
    fail "the image does not start with the 1.70.02-2 layers"
fi
config_filter='{Cmd, Entrypoint, Env, User, WorkingDir, ExposedPorts, Volumes}'
if [ "$(docker image inspect --format '{{json .Config}}' "$image_ref" | jq -cS "$config_filter")" = \
     "$(docker image inspect --format '{{json .Config}}' "$BASE_IMAGE" | jq -cS "$config_filter")" ]; then
    pass "command, environment, user, ports and volumes match 1.70.02-2"
else
    fail "image configuration differs from 1.70.02-2"
fi
# One container per image prints everything the comparisons need, in
# sections: packages, PHP modules (FPM and CLI), a sha256 manifest of
# /kod_sources and the sha256 and mode of each install script.
report_sh='
echo "@@packages"
dpkg-query -W -f="\${db:Status-Abbrev}|\${Package}:\${Architecture}|\${Version}\n" | awk -F"|" "\$1 ~ /^ii/ {print \$2, \$3}" | sort
echo "@@php-fpm8.3"
php-fpm8.3 -m 2>/dev/null
echo "@@php8.3"
php8.3 -m 2>/dev/null
echo "@@kod_sources"
cd /kod_sources && find . -type f -print0 | sort -z | xargs -0 sha256sum
echo "@@scripts"
for f in /scripts/install/kod.sh /scripts/install/kodbox-install-step.php /scripts/install/kodbox-install-check.php \
    /etc/my_init.d/30_installer.sh /usr/local/bin/appbox-installed-callback /etc/service/appbox-callback/run; do
    [ -f "$f" ] && echo "$f $(sha256sum "$f" | cut -d" " -f1) $(stat -c %a "$f")"
done
echo "@@end"
'
docker run --rm --network none --entrypoint sh "$BASE_IMAGE" -c "$report_sh" > "$work_dir/base-report" \
    || die "cannot read the 1.70.02-2 image"
docker run --rm --network none --entrypoint sh "$image_ref" -c "$report_sh" > "$work_dir/image-report" \
    || die "cannot read $image_ref"
section() { awk -v s="@@$1" '$0 == s {on = 1; next} /^@@/ {on = 0} on' "$2"; }
for part in packages php-fpm8.3 php8.3 kod_sources; do
    section "$part" "$work_dir/base-report" > "$work_dir/base-$part"
    section "$part" "$work_dir/image-report" > "$work_dir/image-$part"
done
grep -qx '@@end' "$work_dir/image-report" || fail "the image report is incomplete"
if [ "$(wc -l < "$work_dir/base-packages")" -gt 100 ] && cmp -s "$work_dir/base-packages" "$work_dir/image-packages"; then
    pass "installed packages are identical to 1.70.02-2 ($(wc -l < "$work_dir/image-packages"))"
else
    fail "installed packages differ from 1.70.02-2"
fi
for sapi in php-fpm8.3 php8.3; do
    if [ "$(wc -l < "$work_dir/base-$sapi")" -gt 20 ] && cmp -s "$work_dir/base-$sapi" "$work_dir/image-$sapi"; then
        pass "$sapi -m is identical to 1.70.02-2"
    else
        fail "$sapi -m differs from 1.70.02-2"
    fi
done
LC_ALL=C sort "$work_dir/image-kod_sources" > "$work_dir/image-kod_sources.sorted"
LC_ALL=C sort "$release_dir/kod_sources-1.70.03.sha256" > "$work_dir/want-kod_sources"
if [ "$(wc -l < "$work_dir/want-kod_sources")" -gt 3000 ] \
    && cmp -s "$work_dir/want-kod_sources" "$work_dir/image-kod_sources.sorted"; then
    pass "/kod_sources is exactly release/kod_sources-1.70.03.sha256 ($(wc -l < "$work_dir/image-kod_sources") files)"
else
    fail "/kod_sources differs from release/kod_sources-1.70.03.sha256"
    diff "$work_dir/want-kod_sources" "$work_dir/image-kod_sources.sorted" | head -20 >&2
fi
if docker run --rm --network none --entrypoint sh "$image_ref" -c \
    "grep -qF \"define('KOD_VERSION','1.70');\" /kod_sources/config/version.php && grep -qF \"define('KOD_VERSION_BUILD','03');\" /kod_sources/config/version.php"; then
    pass "/kod_sources/config/version.php is Kodbox 1.70.03"
else
    fail "/kod_sources/config/version.php is not Kodbox 1.70.03"
fi
changed=$(LC_ALL=C sort "$work_dir/base-kod_sources" | diff - "$work_dir/want-kod_sources" | grep -c '^[<>]')
echo "/kod_sources: $changed manifest lines differ from 1.70.02-2 (upstream 1.70.02 to 1.70.03 changes 12 files; 1.70.02-2 also holds five .DS_Store files)"
script_check() {
    local repo_file=$1 image_file=$2 want_mode=$3 want_sum
    want_sum=$(sha256sum "$repo_dir/$repo_file" | cut -d' ' -f1)
    if section scripts "$work_dir/image-report" | grep -qx "$image_file $want_sum $want_mode"; then
        pass "$image_file is the repository's $repo_file (mode $want_mode)"
    else
        fail "$image_file is not the repository's $repo_file with mode $want_mode"
    fi
}
script_check scripts/kod.sh /scripts/install/kod.sh 755
script_check scripts/kodbox-install-step.php /scripts/install/kodbox-install-step.php 644
script_check scripts/kodbox-install-check.php /scripts/install/kodbox-install-check.php 644
script_check scripts/30_installer.sh /etc/my_init.d/30_installer.sh 755
script_check scripts/appbox-installed-callback /usr/local/bin/appbox-installed-callback 755
script_check scripts/appbox-callback-run /etc/service/appbox-callback/run 755
kod_code=$(grep -v '^[[:space:]]*#' "$repo_dir/scripts/kod.sh")
if echo "$kod_code" | grep -Eq 'set -[a-z]*x|curl|php-fpm|nginx|HTTP_DOMAIN'; then
    fail "kod.sh traces commands or still uses HTTP, php-fpm or nginx"
else
    pass "kod.sh does not trace commands and does not start php-fpm or nginx or use HTTP"
fi
if bash "$repo_dir/tests/test-installed-callback.sh" > "$work_dir/callback-tests" 2>&1; then
    pass "tests/test-installed-callback.sh ($(grep -c '^ok' "$work_dir/callback-tests") checks)"
else
    cat "$work_dir/callback-tests" >&2
    fail "tests/test-installed-callback.sh failed"
fi

echo "== Fresh install with install requests racing it"
fresh=$run_id-fresh
new_volume "$fresh-ph"
new_volume "$fresh-data"
write_env "$work_dir/fresh.env" "$fresh_pass"
start_container "$fresh" "$image_ref" "$work_dir/fresh.env" "$fresh-ph" "$fresh-data" \
    || die "cannot start $fresh"
docker exec -d "$fresh" bash -c "$attack_sh" attack 1800 "$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$attacker_pass")"
start_mock "$fresh"
wait_for_web "$fresh"
web=$?
if [ "$web" -eq 0 ]; then
    pass "the new container serves Kodbox after its first start"
    sleep 5
    docker exec "$fresh" touch /var/log/gate-attack.stop
    sleep 2
    docker exec "$fresh" cat /var/log/gate-attack.log > "$work_dir/attack.log"
    attempts=$(grep -c . "$work_dir/attack.log")
    unanswered=$(grep -c ' HTTP000$' "$work_dir/attack.log")
    accepted=$(grep -Ec '"code": ?true' "$work_dir/attack.log")
    rejected_db=$(grep -E ' action=db ' "$work_dir/attack.log" | grep -E ' HTTP200$' | grep -Ec '"code": ?false')
    rejected_user=$(grep -E ' action=user ' "$work_dir/attack.log" | grep -E ' HTTP200$' | grep -Ec '"code": ?false')
    echo "install requests: $attempts sent, $unanswered unanswered during the install, $accepted accepted," \
        "$rejected_db database and $rejected_user administrator steps rejected afterwards"
    sed -n '$p' "$work_dir/attack.log"
    if [ "$accepted" -eq 0 ] && [ "$unanswered" -ge 10 ] && [ "$rejected_db" -ge 1 ] && [ "$rejected_user" -ge 1 ]; then
        pass "no unauthenticated install/index/save request was accepted during or after the first start"
    else
        fail "unauthenticated install requests: $accepted accepted, $unanswered unanswered, $rejected_db/$rejected_user rejected after start"
    fi
    if docker exec "$fresh" sh -c 'test -f /home/appbox/data/system/install.lock && test -f /home/appbox/public_html/config/setting_user.php'; then
        pass "install.lock and config/setting_user.php exist"
    else
        fail "install.lock or config/setting_user.php is missing"
    fi
    if docker logs "$fresh" 2>&1 | grep -q "Installing Kodbox: creating the database" \
        && docker logs "$fresh" 2>&1 | grep -q "^Kodbox is installed$"; then
        pass "kod.sh installed Kodbox from the command line"
    else
        fail "the log does not show kod.sh installing Kodbox"
    fi
    if logs_contain_secret "$fresh" "$fresh_pass"; then
        fail "ADMIN_PASS appears in the container log"
    else
        pass "ADMIN_PASS is not in the container log"
    fi
    if docker exec "$fresh" grep -rqsF -- "$fresh_pass" /home/appbox/data /home/appbox/public_html /home/appbox/logs; then
        fail "ADMIN_PASS is stored in plain text on the volumes"
    else
        pass "ADMIN_PASS is not stored in plain text on the volumes"
    fi
    if login "$fresh" admin "$fresh_pass" | json_ok; then
        pass "the administrator logs in with ADMIN_PASS through the login API"
    else
        fail "the administrator cannot log in with ADMIN_PASS"
    fi
    if login "$fresh" admin "$attacker_pass" | json_ok; then
        fail "the attacker's password logs in as administrator"
    else
        pass "the attacker's password does not log in"
    fi
    if docker exec "$fresh" curl -s -m 10 -X POST --data "action=user&name=admin&password=Another1!pass" \
        'http://127.0.0.1/?install/index/save' | grep -Eq '"code": ?false'; then
        pass "install/index/save is rejected once Kodbox runs"
    else
        fail "install/index/save is not rejected once Kodbox runs"
    fi
    for _ in $(seq 1 20); do
        [ "$(callback_requests "$fresh")" -ge 1 ] && break
        sleep 2
    done
    sleep 3
    callbacks=$(docker exec "$fresh" cat /var/log/gate-callback.log 2>/dev/null)
    if [ "$(echo "$callbacks" | grep -c .)" -eq 1 ] \
        && echo "$callbacks" | grep -qF "\"path\": \"/v1/apps/installed/$callback_id?callback_token=$callback_query_token\"" \
        && echo "$callbacks" | grep -qF "\"token\": \"$callback_header_token\"" \
        && ! docker exec "$fresh" test -e /etc/appbox_callback_pending; then
        pass "one installed callback was sent after the install"
    else
        fail "installed callback: expected one request, got: $callbacks"
    fi
    db_snapshot "$fresh" > "$work_dir/fresh-before-restart" || fail "cannot read the Kodbox database"

    echo "== Restart"
    docker exec "$fresh" rm -f /var/log/gate-callback.log
    docker restart -t 20 "$fresh" >/dev/null
    start_mock "$fresh"
    if wait_for_web "$fresh"; then
        pass "the container serves Kodbox after a restart"
    else
        fail "the container does not serve Kodbox after a restart"
    fi
    sleep 10
    if [ "$(docker logs "$fresh" 2>&1 | grep -c 'Installing Kodbox')" -eq 1 ] \
        && [ "$(callback_requests "$fresh")" -eq 0 ]; then
        pass "the restart neither installs again nor sends another callback"
    else
        fail "the restart installed again or sent another callback"
    fi
    db_snapshot "$fresh" > "$work_dir/fresh-after-restart" || true
    if cmp -s "$work_dir/fresh-before-restart" "$work_dir/fresh-after-restart"; then
        pass "the database and administrator are unchanged by the restart"
    else
        fail "the database or administrator changed on restart"
    fi
    if login "$fresh" admin "$fresh_pass" | json_ok; then
        pass "the administrator logs in after the restart"
    else
        fail "the administrator cannot log in after the restart"
    fi
else
    fail "the new container did not serve Kodbox (wait result $web)"
    docker logs "$fresh" 2>&1 | tail -40 | sed "s/$(printf '%s' "$fresh_pass" | sed 's/[]\/$*.^[]/\\&/g')/[password]/g" >&2
fi
docker rm -f "$fresh" >/dev/null 2>&1

echo "== Fresh install with a password Kodbox refuses"
weak=$run_id-weak
new_volume "$weak-ph"
new_volume "$weak-data"
write_env "$work_dir/weak.env" "$weak_pass"
start_container "$weak" "$image_ref" "$work_dir/weak.env" "$weak-ph" "$weak-data" || die "cannot start $weak"
for attempt in 1 2; do
    if wait_for_exit "$weak"; then
        code=$(docker inspect -f '{{.State.ExitCode}}' "$weak")
        logs=$(docker logs "$weak" 2>&1)
        state=$(docker run --rm --network none -v "$weak-ph:/ph" -v "$weak-data:/data" --entrypoint sh "$BASE_IMAGE" \
            -c 'ls /data/system/install.lock /ph/config/setting_user.php 2>/dev/null | wc -l')
        pending=absent
        docker cp "$weak:/etc/appbox_callback_pending" - >/dev/null 2>&1 && pending=present
        docker cp "$weak:/etc/installer30_completed" - >/dev/null 2>&1 && pending="$pending, installer marked complete"
        if [ "$code" -ne 0 ] \
            && [ "$(echo "$logs" | grep -c 'kod.sh: Kodbox installation failed')" -eq "$attempt" ] \
            && ! echo "$logs" | grep -q 'Booting runit' \
            && [ "$state" = 0 ] && [ "$pending" = absent ]; then
            pass "start $attempt: the container stopped (exit $code) before serving anything, with no callback marked and no install.lock"
        else
            fail "start $attempt: exit $code, install files $state, callback flag $pending"
        fi
    else
        fail "start $attempt: the container is still running with a refused password"
    fi
    [ "$attempt" -eq 1 ] && docker start "$weak" >/dev/null
done
docker rm -f "$weak" >/dev/null 2>&1

# upgrade_from <label> <old image> <http|cli> <name suffix>: the old image
# installs Kodbox on new volumes and gets a second user and a file on the data
# volume; the candidate then starts on the same volumes with a different
# ADMIN_PASS.
upgrade_from() {
    local label=$1 old_image=$2 mode=$3 up=$run_id-up-$4
    local before="$work_dir/up-$4-before" after="$work_dir/up-$4-after"
    local token role added logs
    echo "== Upgrade from $label on the same volumes"
    new_volume "$up-ph"
    new_volume "$up-data"
    if [ "$mode" = http ]; then
        # 1.70.02-1 installs over HTTP_DOMAIN; point it at the container itself.
        # Its kod.sh traces its last command (rm -rf /code_sources) when it is
        # done; the callback loop after it then waits forever for api.cylo.io
        # (no network), which is fine: the volumes hold an installed Kodbox.
        write_env "$work_dir/old.env" "$old_pass" http://127.0.0.1
        start_container "$up-old" "$old_image" "$work_dir/old.env" "$up-ph" "$up-data" || die "cannot start $up-old"
        if ! wait_for_log "$up-old" "+ rm -rf /code_sources" \
            || ! docker exec "$up-old" test -f /home/appbox/data/system/install.lock; then
            fail "$label did not install Kodbox"
            return
        fi
        docker exec "$up-old" sh -c '/usr/sbin/php-fpm8.3 --fpm-config /home/appbox/config/php-fpm/php-fpm.conf; /usr/sbin/nginx -c /home/appbox/config/nginx/nginx.conf'
    else
        # 1.70.02-2 installs from the command line before its web server starts.
        write_env "$work_dir/old.env" "$old_pass"
        start_container "$up-old" "$old_image" "$work_dir/old.env" "$up-ph" "$up-data" || die "cannot start $up-old"
        start_mock "$up-old"
        if ! wait_for_web "$up-old" \
            || ! docker exec "$up-old" test -f /home/appbox/data/system/install.lock; then
            fail "$label did not install Kodbox"
            return
        fi
    fi
    pass "$label installed Kodbox on the new volumes"
    wait_for_web "$up-old" || fail "$label does not serve Kodbox"
    token=$(login "$up-old" admin "$old_pass" | python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["info"] if d.get("code") is True else "")' 2>/dev/null)
    role=$(db_snapshot "$up-old" | awk -F'|' '$1 == "1" {print $3}')
    added=$(docker exec "$up-old" curl -s -m 60 --data-urlencode "name=$second_user" \
        --data-urlencode "password=$second_pass" --data-urlencode "roleID=$role" \
        --data-urlencode 'groupInfo={"1":"1"}' --data-urlencode 'sizeMax=0' \
        "http://127.0.0.1/?admin/member/add&accessToken=$token")
    if [ -n "$token" ] && echo "$added" | json_ok && login "$up-old" "$second_user" "$second_pass" | json_ok; then
        pass "$label: the administrator logs in and adds user $second_user"
    else
        fail "$label: could not log in and add a user: $added"
    fi
    docker exec "$up-old" sh -c 'echo gate-marker > /home/appbox/data/gate-marker.txt'
    db_snapshot "$up-old" > "$before" || fail "cannot read the $label database"
    docker rm -f "$up-old" >/dev/null

    write_env "$work_dir/new.env" "$new_pass"
    start_container "$up-new" "$image_ref" "$work_dir/new.env" "$up-ph" "$up-data" || die "cannot start $up-new"
    start_mock "$up-new"
    if ! wait_for_web "$up-new"; then
        fail "the candidate does not serve Kodbox on the $label volumes"
        docker logs "$up-new" 2>&1 | tail -40 >&2
        docker rm -f "$up-new" >/dev/null 2>&1
        return
    fi
    pass "the candidate serves Kodbox on the $label volumes"
    if docker exec "$up-new" sh -c "grep -qF \"define('KOD_VERSION_BUILD','03');\" /home/appbox/public_html/config/version.php"; then
        pass "the updated instance runs Kodbox 1.70.03"
    else
        fail "the updated instance does not run Kodbox 1.70.03"
    fi
    logs=$(docker logs "$up-new" 2>&1)
    if echo "$logs" | grep -q '^Kodbox is already installed: keeping the existing data and administrator$' \
        && ! echo "$logs" | grep -q 'Kodbox install step'; then
        pass "the update kept the installation and ran no install step"
    else
        fail "the update ran an install step"
    fi
    db_snapshot "$up-new" > "$after" || true
    if [ -s "$before" ] && cmp -s "$before" "$after"; then
        pass "database file, users, roles and password hashes are unchanged ($(grep -c '|' "$after") users)"
    else
        fail "the database changed on update"
        diff "$before" "$after" | sed 's/|[^|]*$/|<hash>/' >&2
    fi
    if [ "$(docker exec "$up-new" cat /home/appbox/data/gate-marker.txt 2>/dev/null)" = gate-marker ]; then
        pass "files on the data volume are kept"
    else
        fail "a file on the data volume was lost"
    fi
    if login "$up-new" admin "$old_pass" | json_ok && login "$up-new" "$second_user" "$second_pass" | json_ok; then
        pass "the administrator and $second_user log in with their $label passwords"
    else
        fail "a $label login no longer works after the update"
    fi
    if login "$up-new" admin "$new_pass" | json_ok; then
        fail "the update reset the administrator password to ADMIN_PASS"
    else
        pass "the update did not reset the administrator password"
    fi
    if docker exec "$up-new" curl -s -m 10 -X POST --data "action=user&name=admin&password=Another1!pass" \
        'http://127.0.0.1/?install/index/save' | grep -Eq '"code": ?false'; then
        pass "install/index/save is rejected after the update"
    else
        fail "install/index/save is not rejected after the update"
    fi
    for _ in $(seq 1 20); do
        [ "$(callback_requests "$up-new")" -ge 1 ] && break
        sleep 2
    done
    if [ "$(callback_requests "$up-new")" -eq 1 ]; then
        pass "the update sent one installed callback"
    else
        fail "the update sent $(callback_requests "$up-new") installed callbacks, expected 1"
    fi
    if logs_contain_secret "$up-new" "$new_pass"; then
        fail "ADMIN_PASS appears in the updated container's log"
    else
        pass "ADMIN_PASS is not in the updated container's log"
    fi
    docker rm -f "$up-new" >/dev/null 2>&1
}

upgrade_from 1.70.02-1 "$OLD_IMAGE" http v1
upgrade_from 1.70.02-2 "$BASE_IMAGE" cli v2

echo "== Registry tag must not exist"
registry=${registry_ref%%/*}
repository_and_tag=${registry_ref#*/}
repository=${repository_and_tag%:*}
tag=${repository_and_tag##*:}
[ "$repository" != "$repository_and_tag" ] || die "image reference has no tag"

registry_auth=$(jq -r --arg host "$registry" '.auths[$host].auth // empty' "$HOME/.docker/config.json")
[ -n "$registry_auth" ] || die "no stored credentials for $registry"
registry_body="$work_dir/registry-body"
registry_get() {
    printf 'header = "Authorization: Basic %s"\n' "$registry_auth" \
        | curl -sS -K - -o "$registry_body" -w '%{http_code}' \
            -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
            "https://$registry$1"
}
api_status=$(registry_get /v2/) || die "registry unreachable"
[ "$api_status" = 200 ] || die "registry API check returned HTTP $api_status"
base_status=$(registry_get "/v2/$repository/manifests/1.70.02-2") || die "registry unreachable"
[ "$base_status" = 200 ] || die "registry cannot read the existing 1.70.02-2 tag (HTTP $base_status); state is indeterminate"
manifest_status=$(registry_get "/v2/$repository/manifests/$tag") || die "registry unreachable"
case "$manifest_status" in
    200) fail "$registry_ref already exists in the registry" ;;
    404)
        if grep -q 'MANIFEST_UNKNOWN' "$registry_body"; then
            pass "$registry_ref is not in the registry yet"
        else
            fail "registry returned 404 without MANIFEST_UNKNOWN: $(head -c 300 "$registry_body")"
        fi
        ;;
    *) fail "registry returned HTTP $manifest_status for $registry_ref" ;;
esac

if [ "$failures" -ne 0 ]; then
    echo "FAILED: $image_ref ($failures check(s) failed)" >&2
    exit 1
fi
echo "PASS: $image_ref"
