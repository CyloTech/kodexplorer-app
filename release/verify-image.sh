#!/bin/sh
# Release gate for Kodbox 1.70.02-1: the deployed kodbox:1.70.02 image with
# its php8.3 packages upgraded from Ubuntu noble-security.
#
# Usage: release/verify-image.sh <registry>/<repository>:<tag>
#
# Every check runs and reports PASS or FAIL. The script exits 0 only when all
# of them passed and the registry definitively reports that the tag does not
# exist yet. Any indeterminate registry answer fails.
#
# Checks: every php8.3 package is at least the fixed noble build and its
# changelog names both CVEs; only php8.3-source packages differ from the
# deployed image; php-fpm8.3 -m and php8.3 -m are identical to the deployed
# image; php-fpm8.3 -t, apache2ctl -t and nginx -t pass; Kodbox, the install
# scripts and the image configuration are unchanged; a multipart upload is
# parsed by the PHP built-in server; a fresh Kodbox install (the base
# image's nginx/php-fpm installer plus kod.sh) serves the Kodbox page, a PHP
# page and a parsed multipart upload through nginx and php-fpm8.3
# (release/fpm-smoke.sh); and the tag is absent from the registry.
#
# A trial build is tagged under another name (local/kodbox-trial:<tag>). Set
# VERIFY_REGISTRY_REF to the repo.cylo.net reference the release will use and
# the registry check looks that tag up instead of the image reference.
set -eu

# The deployed 1.70.02 image this release is built FROM.
BASE_IMAGE=repo.cylo.net/kodbox@sha256:7e65783582d949e0cb8d197eb09736fb4d50e8a8eda94ff0200ceb5211925ae4
# Last noble php8.3 build published before the 21 October 2026 disclosure.
# The release must carry a newer one.
PHP83_PRE_DISCLOSURE=8.3.6-0ubuntu0.24.04.12
# First noble php8.3 build with the fix for CVE-2026-109618 and
# CVE-2026-109619 (noble-security, 21 October 2026). Every installed php8.3
# package must be at least this version, whatever the build argument says.
PHP83_FIXED=8.3.6-0ubuntu0.24.04.13
# Install scripts of the deployed image; this release must not change them.
KOD_SH_SHA256=402504d216ed60d2b6e01071d028c76e9dcc3e1f1b3e985301b8ee9757d89773
INSTALLER_SHA256=60def63b03e3e99b15a8d8763cb09e3703366231b51c7a5d53700a74b0d10789

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
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

docker image inspect "$image_ref" >/dev/null 2>&1 || die "$image_ref is not a local image"
docker image inspect "$BASE_IMAGE" >/dev/null 2>&1 || docker pull -q "$BASE_IMAGE" >/dev/null \
    || die "cannot read the base image $BASE_IMAGE"
in_image() {
    entrypoint=$1
    shift
    docker run --rm --network none --entrypoint "$entrypoint" "$image_ref" "$@"
}
in_image_sh() {
    docker run --rm --network none -v "$release_dir:/release:ro" --entrypoint sh "$image_ref" "$@"
}

echo "== PHP packages"
packages=$(docker run --rm --network none --entrypoint dpkg-query "$image_ref" \
    -W -f='${db:Status-Abbrev}|${Package}|${source:Package}|${Version}\n' \
    | awk -F'|' '$1 ~ /^ii/ && $3 == "php8.3" {print $2, $4}' | sort)
echo "$packages"
if [ -z "$packages" ]; then
    fail "no php8.3 packages installed"
else
    if echo "$packages" | awk '{print $1}' | diff -u "$release_dir/expected-php83-packages.txt" -; then
        pass "the installed php8.3 packages are the ones the deployed image has"
    else
        fail "the set of installed php8.3 packages differs from the deployed image"
    fi
    versions=$(echo "$packages" | awk '{print $2}' | sort -u)
    if [ "$(echo "$versions" | wc -l)" -ne 1 ]; then
        fail "php8.3 packages have mixed versions: $(echo "$versions" | tr '\n' ' ')"
    else
        php_version=$versions
        min_version=$(docker image inspect --format '{{index .Config.Labels "net.cylo.php83-min-version"}}' "$image_ref")
        if [ -z "$min_version" ]; then
            fail "image has no net.cylo.php83-min-version label"
        elif in_image dpkg --compare-versions "$php_version" ge "$min_version"; then
            pass "php8.3 $php_version is at least the release pin $min_version"
        else
            fail "php8.3 $php_version is older than the release pin $min_version"
        fi
        if in_image dpkg --compare-versions "$php_version" gt "$PHP83_PRE_DISCLOSURE"; then
            pass "php8.3 $php_version is newer than the pre-disclosure $PHP83_PRE_DISCLOSURE"
        else
            fail "php8.3 $php_version is not newer than $PHP83_PRE_DISCLOSURE, so it does not include the 21 October 2026 fix"
        fi
    fi
    # One container compares every package; it prints "ok <package>" or
    # "old <package> <version>" per package, so a lost answer cannot pass.
    min_check=$(in_image_sh -c '
        dpkg-query -W -f="\${db:Status-Abbrev}|\${Package}|\${source:Package}|\${Version}\n" \
            | awk -F"|" "\$1 ~ /^ii/ && \$3 == \"php8.3\" {print \$2, \$4}" \
            | while read -r pkg version; do
                if dpkg --compare-versions "$version" ge "$1"; then
                    echo "ok $pkg"
                else
                    echo "old $pkg $version"
                fi
            done' sh "$PHP83_FIXED") || min_check=
    checked=$(echo "$min_check" | grep -c '^ok ' || true)
    below_fixed=$(echo "$min_check" | sed -n 's/^old //p')
    if [ -n "$below_fixed" ]; then
        fail "php8.3 packages older than the fixed $PHP83_FIXED: $(echo "$below_fixed" | tr '\n' ' ')"
    elif [ "$checked" -ne "$(echo "$packages" | wc -l)" ]; then
        fail "could only confirm $checked php8.3 packages against $PHP83_FIXED"
    else
        pass "all $checked installed php8.3 packages are at least the fixed $PHP83_FIXED"
    fi
fi
echo "-- php8.3-common changelog, latest entry"
in_image_sh -c 'zcat /usr/share/doc/php8.3-common/changelog.Debian.gz | sed -n "1,/^ --/p"' || true
if in_image_sh -c 'zcat /usr/share/doc/php8.3-common/changelog.Debian.gz | sed -n "1,/^ --/p" | grep -q "CVE-2026-109618" && zcat /usr/share/doc/php8.3-common/changelog.Debian.gz | sed -n "1,/^ --/p" | grep -q "109619"'; then
    pass "the latest php8.3 changelog entry names CVE-2026-109618 and CVE-2026-109619"
else
    fail "the latest php8.3 changelog entry does not name CVE-2026-109618 and CVE-2026-109619"
fi

echo "== Packages changed from the deployed image"
package_list() {
    docker run --rm --network none --entrypoint dpkg-query "$1" \
        -W -f='${db:Status-Abbrev}|${Package}:${Architecture}|${source:Package}|${Version}\n' \
        | awk -F'|' '$1 ~ /^ii/ {print $2, $3, $4}' | sort
}
package_list "$BASE_IMAGE" > "$work_dir/base-packages"
package_list "$image_ref" > "$work_dir/image-packages"
# Lines are "<package>:<arch> <source> <version>"; a changed package shows up
# once on each side.
changed=$(diff "$work_dir/base-packages" "$work_dir/image-packages" | sed -n 's/^[<>] //p' \
    | awk '{print $1, $2}' | sort -u)
echo "$changed"
added_or_removed=$(comm -3 "$work_dir/base-packages" "$work_dir/image-packages" | awk '{print $1}' \
    | sort | uniq -u)
outside_php83=$(echo "$changed" | awk 'NF && $2 != "php8.3" {print $1}')
if [ "$(wc -l < "$work_dir/base-packages")" -lt 100 ] || [ "$(wc -l < "$work_dir/image-packages")" -lt 100 ]; then
    fail "could not list the installed packages of both images"
elif [ -n "$added_or_removed" ]; then
    fail "packages were added or removed: $(echo "$added_or_removed" | tr '\n' ' ')"
elif [ -n "$outside_php83" ]; then
    fail "packages outside the php8.3 source changed: $(echo "$outside_php83" | tr '\n' ' ')"
else
    pass "only packages built from the php8.3 source changed"
fi

echo "== PHP modules"
if in_image php-fpm8.3 -m | diff -u "$release_dir/expected-fpm-modules.txt" -; then
    pass "FPM module list matches the recorded list"
else
    fail "FPM module list differs from the recorded list"
fi
for sapi in php-fpm8.3 php8.3; do
    docker run --rm --network none --entrypoint "$sapi" "$BASE_IMAGE" -m > "$work_dir/base-modules" \
        || die "cannot list $sapi modules of the base image"
    if in_image "$sapi" -m | diff -u "$work_dir/base-modules" -; then
        pass "$sapi -m is identical to the deployed image"
    else
        fail "$sapi -m differs from the deployed image"
    fi
done

echo "== Configuration tests"
if in_image php-fpm8.3 -t; then
    pass "php-fpm8.3 -t"
else
    fail "php-fpm8.3 configuration test failed"
fi
if in_image apache2ctl -t; then
    pass "apache2ctl -t (loads libapache2-mod-php8.3)"
else
    fail "apache2ctl -t failed"
fi
if in_image nginx -t; then
    pass "nginx -t"
else
    fail "nginx -t failed"
fi

echo "== Kodbox code and install scripts"
if in_image_sh -c "grep -q \"define('KOD_VERSION','1.70');\" /kod_sources/config/version.php && grep -q \"define('KOD_VERSION_BUILD','02');\" /kod_sources/config/version.php"; then
    pass "/kod_sources is Kodbox 1.70 build 02"
else
    fail "/kod_sources is not Kodbox 1.70 build 02"
fi
if in_image_sh -c "printf '%s  %s\n%s  %s\n' $KOD_SH_SHA256 /scripts/install/kod.sh $INSTALLER_SHA256 /etc/my_init.d/30_installer.sh | sha256sum -c -"; then
    pass "kod.sh and 30_installer.sh are unchanged"
else
    fail "kod.sh or 30_installer.sh differs from the deployed image"
fi

echo "== Image configuration"
config_filter='{Cmd, Entrypoint, Env, User, WorkingDir, ExposedPorts, Volumes}'
if [ "$(docker image inspect --format '{{json .Config}}' "$image_ref" | jq -cS "$config_filter")" = \
     "$(docker image inspect --format '{{json .Config}}' "$BASE_IMAGE" | jq -cS "$config_filter")" ]; then
    pass "command, environment, user, ports and volumes match the deployed image"
else
    fail "image configuration differs from the deployed image"
fi
if [ -z "$(in_image_sh -c 'apt-get -s autoremove 2>/dev/null | grep "^Remv" || true')" ]; then
    pass "the first-boot apt autoremove removes nothing"
else
    fail "apt autoremove would remove packages at first boot"
fi

echo "== Multipart upload (PHP built-in server)"
if in_image_sh /release/multipart-smoke.sh; then
    pass "multipart upload smoke test"
else
    fail "multipart upload smoke test failed"
fi

echo "== Kodbox install, PHP page and multipart upload through nginx and php-fpm"
if in_image_sh /release/fpm-smoke.sh; then
    pass "fresh Kodbox install serves pages and parses a multipart upload through php-fpm"
else
    fail "nginx and php-fpm smoke test failed"
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
