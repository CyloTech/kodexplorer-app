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

# Install scripts of the deployed 4.35-6 image; this release must not change
# them.
KOD_SH_SHA256=baff9ba9e5a53a1051e33adffb542d2a079b7d7971927caf89e2b6c4126e41b5
INSTALLER_SHA256=174bd8710ee1ee786cc27d8f1ee48fac7852f241e971c50b85a55a7ebf2244c9

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
case "$expected_version" in
    *+cylo*) ;;
    *) fail "net.cylo.php72-version label is missing or not a local build: '$expected_version'" ;;
esac
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
    *+cylo*) pass "php-fpm7.2 is the local rebuild" ;;
    *) fail "php-fpm7.2 is not the local rebuild" ;;
esac
echo "-- php7.2-common changelog, latest entry"
in_image_sh -c 'zcat /usr/share/doc/php7.2-common/changelog.Debian.gz | sed -n "1,/^ --/p"' || true

echo "== FPM modules"
if in_image php-fpm7.2 -m | diff -u "$release_dir/expected-fpm-modules.txt" -; then
    pass "FPM module list matches the deployed image"
else
    fail "FPM module list differs from the deployed image"
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
    pass "kod.sh and 30_installer.sh are unchanged"
else
    fail "kod.sh or 30_installer.sh differs from the deployed image"
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

echo "== Registry tag must not exist"
registry=${registry_ref%%/*}
repository_and_tag=${registry_ref#*/}
repository=${repository_and_tag%:*}
tag=${repository_and_tag##*:}
[ "$repository" != "$repository_and_tag" ] || die "image reference has no tag"

registry_auth=$(jq -r --arg host "$registry" '.auths[$host].auth // empty' "$HOME/.docker/config.json")
[ -n "$registry_auth" ] || die "no stored credentials for $registry"

registry_body=$(mktemp)
trap 'rm -f "$registry_body"' EXIT

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
