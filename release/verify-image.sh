#!/bin/sh
# Release gate for KODExplorer 4.35-7: the deployed 4.35-6 image with its
# php7.2 packages replaced by the local rebuild from stage 1.
#
# Usage: release/verify-image.sh <registry>/<repository>:<tag>
#
# Every check runs and reports PASS or FAIL. The script exits 0 only when all
# of them passed and the registry definitively reports that the tag does not
# exist yet. Any indeterminate registry answer fails.
#
# A trial build is tagged under another name (local/kodexplorer-trial:<tag>).
# Set VERIFY_REGISTRY_REF to the repo.cylo.net reference the release will use
# and the registry check looks that tag up instead of the image reference.
set -eu

# The exact php7.2 build this release ships (Ubuntu's last public bionic
# source plus php72-patches/, local suffix +cylo2).
EXPECTED_PHP72_VERSION=7.2.24-0ubuntu0.18.04.17+cylo2
# Install scripts. 30_installer.sh is the deployed 4.35-6 file; kod.sh is the
# deployed file (DEPLOYED_KOD_SH_SHA256) plus the guard that keeps installed
# KODExplorer 4.x code and the admin account on a recreated container
# (scripts/kod.sh).
DEPLOYED_KOD_SH_SHA256=baff9ba9e5a53a1051e33adffb542d2a079b7d7971927caf89e2b6c4126e41b5
KOD_SH_SHA256=250464b2255d96eb2df141013a93ed7903727d4b135f04f77100a3e93f4ce3c1
INSTALLER_SHA256=174bd8710ee1ee786cc27d8f1ee48fac7852f241e971c50b85a55a7ebf2244c9
# /etc/my_init.d/05_run_php.sh: recreates /run/php on every start.
RUN_PHP_SHA256=dea866e172ec3700f357dffbec758222e597885830cb8d4a2340c7fd03d039a5
# How long the first-boot installers may take in the runtime checks.
RUNTIME_TIMEOUT=${RUNTIME_TIMEOUT:-900}

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
    repo.cylo.net/kodexplorer:*) ;;
    *) die "registry reference must be repo.cylo.net/kodexplorer:<tag>: $registry_ref" ;;
esac
release_dir=$(cd "$(dirname "$0")" && pwd)
context_dir=$(dirname "$release_dir")

docker image inspect "$image_ref" >/dev/null 2>&1 || die "$image_ref is not a local image"
in_image() {
    entrypoint=$1
    shift
    docker run --rm --network none --entrypoint "$entrypoint" "$image_ref" "$@"
}
in_image_sh() {
    docker run --rm --network none -v "$release_dir:/release:ro" --entrypoint sh "$image_ref" "$@"
}

echo "== Local patches"
patch_count=$(find "$context_dir/php72-patches" -maxdepth 1 -name '*.patch' | wc -l)
check_count=$(find "$release_dir/regression" -maxdepth 1 -name '*.sh' | wc -l)
if [ "$patch_count" -gt 0 ] && [ "$check_count" -gt 0 ]; then
    pass "$patch_count patch(es) in php72-patches/ and $check_count regression check(s)"
else
    fail "php72-patches/ has $patch_count patch(es) and release/regression/ has $check_count check(s); a release needs the multipart fix and its regression check"
fi

echo "== PHP packages"
expected_version=$(docker image inspect --format '{{index .Config.Labels "net.cylo.php72-version"}}' "$image_ref")
echo "expected php7.2 version: ${expected_version:-<missing label>}"
if [ "$expected_version" = "$EXPECTED_PHP72_VERSION" ]; then
    pass "net.cylo.php72-version is $EXPECTED_PHP72_VERSION"
else
    fail "net.cylo.php72-version is '$expected_version', expected $EXPECTED_PHP72_VERSION"
fi
packages=$(docker run --rm --network none --entrypoint dpkg-query "$image_ref" \
    -W -f='${db:Status-Abbrev}|${Package}|${Source}|${Version}\n' \
    | awk -F'|' '{ split($3, src, " "); if (src[1] == "") src[1] = $2 } $1 ~ /^ii/ && src[1] == "php7.2" {print $2, $4}' | sort)
echo "$packages"
if [ -z "$packages" ]; then
    fail "no php7.2 packages installed"
else
    if echo "$packages" | awk '{print $1}' | diff -u "$release_dir/expected-php72-packages.txt" -; then
        pass "the installed php7.2 packages are the ones the deployed image has"
    else
        fail "the set of installed php7.2 packages differs from the deployed image"
    fi
    if [ -n "$expected_version" ] && ! echo "$packages" | awk -v v="$expected_version" '$2 != v' | grep -q .; then
        pass "every php7.2 package is $expected_version"
    else
        fail "some php7.2 packages are not $expected_version"
    fi
fi
fpm_version=$(in_image php-fpm7.2 -v | head -1)
echo "$fpm_version"
case "$fpm_version" in
    "PHP 7.2.24-0ubuntu0.18.04.17+cylo2 "*) pass "php-fpm7.2 -v reports 7.2.24-0ubuntu0.18.04.17+cylo2" ;;
    *) fail "php-fpm7.2 is not the +cylo2 rebuild" ;;
esac
if [ -n "$packages" ]; then
    echo "$packages" | sed 's/^/installed: /'
fi
echo "-- php7.2-common changelog, latest entry"
in_image_sh -c 'zcat /usr/share/doc/php7.2-common/changelog.Debian.gz | sed -n "1,/^ --/p"' || true

echo "== FPM and CLI modules"
if in_image php-fpm7.2 -m | diff -u "$release_dir/expected-fpm-modules.txt" -; then
    pass "FPM module list matches the recorded deployed list"
else
    fail "FPM module list differs from the recorded deployed list"
fi
base_ref_for_modules=$(docker image inspect --format '{{index .Config.Labels "net.cylo.base-image"}}' "$image_ref")
if [ -n "$base_ref_for_modules" ] && { docker image inspect "$base_ref_for_modules" >/dev/null 2>&1 || docker pull -q "$base_ref_for_modules" >/dev/null; }; then
    for sapi in php-fpm7.2 php7.2; do
        if [ "$(docker run --rm --network none --entrypoint "$sapi" "$base_ref_for_modules" -m)" = "$(in_image "$sapi" -m)" ]; then
            pass "$sapi -m is identical to the deployed base image"
        else
            fail "$sapi -m differs from the deployed base image"
        fi
    done
else
    fail "cannot load the base image '$base_ref_for_modules' to compare modules"
fi

echo "== FPM configuration"
if in_image php-fpm7.2 -t; then
    pass "php-fpm7.2 -t"
else
    fail "php-fpm7.2 configuration test failed"
fi

echo "== Base image and install scripts"
base_layers=$(wc -l < "$release_dir/expected-base-layers.txt")
if docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$image_ref" \
    | head -n "$base_layers" | diff -u "$release_dir/expected-base-layers.txt" -; then
    pass "the image sits on the $base_layers layers of the deployed 4.35-6 image"
else
    fail "the image is not built on the deployed 4.35-6 image"
fi
base_ref=$(docker image inspect --format '{{index .Config.Labels "net.cylo.base-image"}}' "$image_ref")
config_filter='{Cmd, Entrypoint, Env, User, WorkingDir, ExposedPorts, Volumes}'
if [ -n "$base_ref" ] && { docker image inspect "$base_ref" >/dev/null 2>&1 || docker pull -q "$base_ref" >/dev/null; } \
    && [ "$(docker image inspect --format '{{json .Config}}' "$image_ref" | jq -cS "$config_filter")" = \
         "$(docker image inspect --format '{{json .Config}}' "$base_ref" | jq -cS "$config_filter")" ]; then
    pass "command, environment, user, ports and volumes match $base_ref"
else
    fail "image configuration differs from the base image '$base_ref'"
fi
if in_image_sh -c "printf '%s  %s\n%s  %s\n' $KOD_SH_SHA256 /scripts/install/kod.sh $INSTALLER_SHA256 /etc/my_init.d/30_installer.sh | sha256sum -c -"; then
    pass "kod.sh is the guarded script and 30_installer.sh is unchanged"
else
    fail "kod.sh or 30_installer.sh is not the expected file"
fi
if [ "$(sha256sum < "$context_dir/scripts/kod.sh" | cut -d' ' -f1)" = "$KOD_SH_SHA256" ]; then
    pass "scripts/kod.sh in the build context is the gated file"
else
    fail "scripts/kod.sh in the build context does not match KOD_SH_SHA256"
fi
if [ -n "$base_ref" ] && [ "$(docker run --rm --network none --entrypoint sha256sum "$base_ref" /scripts/install/kod.sh | cut -d' ' -f1)" = "$DEPLOYED_KOD_SH_SHA256" ]; then
    pass "the base image has the deployed kod.sh"
else
    fail "the base image's kod.sh is not the deployed file"
fi
for f in /scripts/install/kod.sh /etc/my_init.d/05_run_php.sh; do
    perm=$(docker run --rm --network none --entrypoint stat "$image_ref" -c '%a %U:%G' "$f")
    if [ "$perm" = "755 root:root" ]; then pass "$f mode $perm"; else fail "$f mode $perm, expected 755 root:root"; fi
done
if in_image_sh -c "printf '%s  %s\n' $RUN_PHP_SHA256 /etc/my_init.d/05_run_php.sh | sha256sum -c -"; then
    pass "05_run_php.sh is the gated file"
else
    fail "05_run_php.sh is not the expected file"
fi
expected_init=$({ docker run --rm --network none --entrypoint ls "$base_ref" /etc/my_init.d; echo 05_run_php.sh; } | LC_ALL=C sort | tr '\n' ' ')
image_init=$(in_image ls /etc/my_init.d | LC_ALL=C sort | tr '\n' ' ')
if [ "$image_init" = "$expected_init" ]; then
    pass "my_init.d is the deployed set plus 05_run_php.sh ($image_init)"
else
    fail "my_init.d is '$image_init', expected '$expected_init'"
fi
if [ -z "$(in_image_sh -c 'apt-get -s autoremove 2>/dev/null | grep "^Remv" || true')" ]; then
    pass "the first-boot apt autoremove removes nothing"
else
    fail "apt autoremove would remove packages at first boot"
fi

echo "== Multipart upload"
if in_image_sh /release/multipart-smoke.sh; then
    pass "multipart upload smoke test"
else
    fail "multipart upload smoke test failed"
fi

echo "== Regression checks"
for check in "$release_dir"/regression/*.sh; do
    [ -e "$check" ] || continue
    name=$(basename "$check")
    if in_image_sh "/release/regression/$name"; then
        pass "regression check $name"
    else
        fail "regression check $name failed"
    fi
done

echo "== Runtime: update from the deployed image and fresh install"
# Run the images the way the platform runs app 103: --init, the public_html
# and data binds, ADMIN_PASS set. APEX_CALLBACK=false keeps the installers
# from calling the production API. The deployed image installs first (it
# clones KODExplorer from GitHub, so it needs the network); the candidate is
# then recreated on the same volumes without a network, like an app update,
# and must keep the installed code, data and users and serve the login page.
# A second volume set is a fresh install of the candidate.
run_id=$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')
rt="gate-kodexplorer-$run_id"
admin_pass=$(od -An -N9 -tx1 /dev/urandom | tr -d ' \n')
rt_cleanup() {
    for c in "$rt-base" "$rt-upd" "$rt-new"; do docker rm -f "$c" >/dev/null 2>&1 || true; done
    for v in "$rt-upd-pub" "$rt-upd-data" "$rt-new-pub" "$rt-new-data"; do docker volume rm -f "$v" >/dev/null 2>&1 || true; done
}
trap 'rt_cleanup; rm -f "${registry_body:-}"' EXIT
rt_start() {
    # rt_start <name> <image> <volume set> <network> [platform]
    # "platform" adds the tmpfs mounts the platform gives every container it
    # creates today (/run, /tmp, /var/tmp); the deployed customer containers
    # predate them, so the deployed image runs without.
    tmpfs_args=
    if [ "${5:-}" = platform ]; then
        tmpfs_args="--tmpfs /run:rw,exec,mode=1777 --tmpfs /tmp:rw,exec,mode=1777 --tmpfs /var/tmp:rw,exec,mode=1777"
    fi
    # shellcheck disable=SC2086
    docker run -d --name "$1" --init --network "$4" $tmpfs_args \
        -e APEX_CALLBACK=false -e ADMIN_PASS="$admin_pass" \
        --mount "type=volume,src=$rt-$3-pub,dst=/home/appbox/public_html" \
        --mount "type=volume,src=$rt-$3-data,dst=/home/appbox/data" \
        "$2" >/dev/null
}
rt_wait() {
    # rt_wait <name>: until the KOD installer has finished
    waited=0
    while ! docker exec "$1" test -f /etc/installer30_completed 2>/dev/null; do
        if [ "$(docker inspect -f '{{.State.Running}}' "$1")" != true ]; then
            docker logs --tail 40 "$1" 2>&1 | sed 's/^/  | /'
            return 1
        fi
        waited=$((waited + 3))
        if [ "$waited" -gt "$RUNTIME_TIMEOUT" ]; then
            docker logs --tail 40 "$1" 2>&1 | sed 's/^/  | /'
            return 1
        fi
        sleep 3
    done
    # runit starts nginx and php-fpm once my_init has run the installers
    waited=0
    until docker exec "$1" curl -s -o /dev/null --fail http://localhost/ 2>/dev/null; do
        waited=$((waited + 2))
        [ "$waited" -le 120 ] || return 1
        sleep 2
    done
}
rt_get() {
    docker exec "$1" curl -s -m 30 "http://localhost/$2"
}
rt_checks() {
    # rt_checks <name> <label>: the checks every candidate container must pass
    login_page=$(rt_get "$1" 'index.php?user/login')
    case "$login_page" in
        *'id="username"'*'id="password"'*) pass "$2: the KODExplorer login page is served" ;;
        *) fail "$2: the login page is not served: $(printf '%s' "$login_page" | head -c 300)" ;;
    esac
    case "$login_page" in
        *box-install*) fail "$2: the KODExplorer installer page is served" ;;
        *) pass "$2: the installer page is not served" ;;
    esac
    login=$(rt_get "$1" "index.php?user/loginSubmit&isAjax=1&name=admin&password=$admin_pass")
    if printf '%s' "$login" | grep -Eq '"code": *true'; then
        pass "$2: admin can log in"
    else
        fail "$2: admin login failed: $(printf '%s' "$login" | head -c 300)"
    fi
    bad_login=$(rt_get "$1" "index.php?user/loginSubmit&isAjax=1&name=admin&password=not-$admin_pass")
    if printf '%s' "$bad_login" | grep -Eq '"code": *false'; then
        pass "$2: a wrong admin password is rejected"
    else
        fail "$2: a wrong admin password was not rejected: $(printf '%s' "$bad_login" | head -c 300)"
    fi
    if docker exec "$1" test -f /home/appbox/data/system/install.lock; then
        pass "$2: install.lock exists"
    else
        fail "$2: install.lock is missing"
    fi
    served_fpm=$(docker exec "$1" sh -c 'ps -eo args | grep "^php-fpm: master" | head -1')
    case "$served_fpm" in
        *php-fpm.conf*) pass "$2: php-fpm is running ($served_fpm)" ;;
        *) fail "$2: no php-fpm master is running" ;;
    esac
    printf '%s' '<?php echo PHP_SAPI, " ", PHP_VERSION, " ", count($_FILES), ":", isset($_FILES["f"]) ? $_FILES["f"]["size"] : -1, ":", isset($_POST["a"]) ? $_POST["a"] : "";' \
        | docker exec -i "$1" sh -c 'cat > /home/appbox/public_html/gate-probe.php'
    probe=$(docker exec "$1" sh -c 'printf hello > /tmp/gate-upload.txt; curl -s -m 30 -F a=b -F f=@/tmp/gate-upload.txt http://localhost/gate-probe.php')
    docker exec "$1" rm -f /home/appbox/public_html/gate-probe.php /tmp/gate-upload.txt
    if [ "$probe" = "fpm-fcgi $EXPECTED_PHP72_VERSION 1:5:b" ]; then
        pass "$2: nginx serves PHP through php-fpm $EXPECTED_PHP72_VERSION and a multipart upload is parsed"
    else
        fail "$2: PHP probe through nginx returned '$probe'"
    fi
    if docker exec "$1" nginx -t -c /home/appbox/config/nginx/nginx.conf >/dev/null 2>&1; then
        pass "$2: nginx -t"
    else
        fail "$2: nginx -t failed"
    fi
    if docker exec "$1" php-fpm7.2 -t --fpm-config /home/appbox/config/php-fpm/php-fpm.conf >/dev/null 2>&1; then
        pass "$2: php-fpm7.2 -t with the runtime configuration"
    else
        fail "$2: php-fpm7.2 -t with the runtime configuration failed"
    fi
    if docker logs "$1" 2>&1 | grep -E 'PHP (Fatal|Parse) error' >/dev/null; then
        fail "$2: PHP fatal errors in the container log"
    else
        pass "$2: no PHP fatal errors in the container log"
    fi
}
rt_restart_check() {
    # rt_restart_check <name> <label>: after a restart (fresh tmpfs /run)
    # php-fpm must come back and serve PHP through nginx.
    docker restart -t 30 "$1" >/dev/null
    if rt_wait "$1"; then
        pass "$2: the container restarted and nginx answers"
    else
        fail "$2: the container did not come back after a restart"
        return 0
    fi
    waited=0
    until docker exec "$1" sh -c 'ps -eo args | grep -q "^php-fpm: master"' 2>/dev/null; do
        waited=$((waited + 2))
        [ "$waited" -le 60 ] || break
        sleep 2
    done
    printf '%s' '<?php echo PHP_SAPI, " ", PHP_VERSION;' | docker exec -i "$1" sh -c 'cat > /home/appbox/public_html/gate-probe.php'
    probe=$(docker exec "$1" curl -s -m 30 http://localhost/gate-probe.php)
    docker exec "$1" rm -f /home/appbox/public_html/gate-probe.php
    if [ "$probe" = "fpm-fcgi $EXPECTED_PHP72_VERSION" ]; then
        pass "$2: after a restart php-fpm serves PHP again"
    else
        fail "$2: after a restart PHP is not served ('$probe'): $(docker logs --tail 5 "$1" 2>&1 | tr '\n' ' ' | head -c 300)"
    fi
}

if [ -n "$base_ref" ] && rt_start "$rt-base" "$base_ref" upd bridge && rt_wait "$rt-base"; then
    pass "the deployed image installed KODExplorer"
    base_login=$(rt_get "$rt-base" "index.php?user/loginSubmit&isAjax=1&name=admin&password=$admin_pass")
    if printf '%s' "$base_login" | grep -Eq '"code": *true'; then
        pass "deployed image: admin can log in"
    else
        fail "deployed image: admin login failed: $(printf '%s' "$base_login" | head -c 300)"
    fi
    # Make the volume look like an instance the in-app updater moved to 4.52,
    # with a user file, a code marker and a customised file.
    docker exec "$rt-base" sh -c "sed -i \"s/define('KOD_VERSION','4.40')/define('KOD_VERSION','4.52')/\" /home/appbox/public_html/config/version.php \
        && echo gate-marker > /home/appbox/public_html/gate-marker.txt \
        && mkdir -p /home/appbox/data/User/admin/home/gate && echo user-file > /home/appbox/data/User/admin/home/gate/file.txt"
    before=$(docker exec "$rt-base" sh -c 'cd /home/appbox && sha256sum public_html/config/version.php public_html/config/config.php public_html/config/define.php public_html/index.php public_html/gate-marker.txt data/User/admin/home/gate/file.txt data/system/system_member.php | sort')
    users_before=$(docker exec "$rt-base" ls /home/appbox/data/User)
    docker stop -t 30 "$rt-base" >/dev/null && docker rm "$rt-base" >/dev/null
    if rt_start "$rt-upd" "$image_ref" upd none platform && rt_wait "$rt-upd"; then
        pass "update: the candidate started on the deployed image's volumes without a network"
        docker logs "$rt-upd" 2>&1 | grep -F 'Keeping the installed KODExplorer' | sed 's/^/  | /'
        after=$(docker exec "$rt-upd" sh -c 'cd /home/appbox && sha256sum public_html/config/version.php public_html/config/config.php public_html/config/define.php public_html/index.php public_html/gate-marker.txt data/User/admin/home/gate/file.txt data/system/system_member.php | sort')
        # The guarded kod.sh keeps install.lock, so the admin account
        # (system_member.php) must be unchanged too.
        if [ "$before" = "$after" ]; then
            pass "update: the installed code (KOD 4.52 marker), config, accounts and user files are unchanged"
        else
            fail "update: code, config or user files changed"
            echo "$before" | sed 's/^/  before /'
            echo "$after" | sed 's/^/  after  /'
        fi
        if [ "$(docker exec "$rt-upd" ls /home/appbox/data/User)" = "$users_before" ]; then
            pass "update: the user directories are unchanged"
        else
            fail "update: the user directories changed"
        fi
        rt_checks "$rt-upd" update
        rt_restart_check "$rt-upd" "update"
    else
        fail "update: the candidate did not finish its installer"
    fi
else
    fail "the deployed image did not install KODExplorer"
fi

if rt_start "$rt-new" "$image_ref" new bridge platform && rt_wait "$rt-new"; then
    pass "fresh install: the candidate installed KODExplorer"
    new_version=$(docker exec "$rt-new" grep -o "KOD_VERSION','[0-9.]*" /home/appbox/public_html/config/version.php)
    if [ "$new_version" = "KOD_VERSION','4.40" ]; then
        pass "fresh install: KODExplorer 4.40 cloned from Git"
    else
        fail "fresh install: unexpected KODExplorer version '$new_version'"
    fi
    rt_checks "$rt-new" "fresh install"
    rt_restart_check "$rt-new" "fresh install"
else
    fail "fresh install: the candidate did not finish its installer"
fi
rt_cleanup

echo "== Registry tag must not exist"
registry=${registry_ref%%/*}
repository_and_tag=${registry_ref#*/}
repository=${repository_and_tag%:*}
tag=${repository_and_tag##*:}
[ "$repository" != "$repository_and_tag" ] || die "image reference has no tag"

registry_auth=$(jq -r --arg host "$registry" '.auths[$host].auth // empty' "$HOME/.docker/config.json")
[ -n "$registry_auth" ] || die "no stored credentials for $registry"

registry_body=$(mktemp)

registry_get() {
    printf 'header = "Authorization: Basic %s"\n' "$registry_auth" \
        | curl -sS -K - -o "$registry_body" -w '%{http_code}' \
            -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
            "https://$registry$1"
}

api_status=$(registry_get /v2/) || die "registry unreachable"
[ "$api_status" = 200 ] || die "registry API check returned HTTP $api_status"

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
