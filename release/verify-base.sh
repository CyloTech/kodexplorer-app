#!/bin/sh
# Gate for re-publishing the deployed KODExplorer 4.35-6 image as the
# immutable base tag repo.cylo.net/kodexplorer:4.35-6-bionic-base.
#
# Usage: release/verify-base.sh <local image reference>
#
# The image is loaded on the builder from a `docker save` of image
# sha256:683ec9821a2f... taken on a node (docker load verifies every layer's
# diff ID). This exits 0 only when the local image has exactly the deployed
# image's 25 layers, creation time and command, and the authenticated
# registry definitively reports that the base tag does not exist yet. Any
# indeterminate registry answer fails. It never pushes.
set -eu

BASE_TAG_REF=repo.cylo.net/kodexplorer:4.35-6-bionic-base
BASE_CREATED=2020-09-29T11:02:01.3861243Z

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ "$#" -eq 1 ] || fail "usage: $0 <local image reference>"
image_ref=$1
case "$image_ref" in
    ''|*[!A-Za-z0-9._/:@-]*) fail "invalid image reference: $image_ref" ;;
esac
release_dir=$(cd "$(dirname "$0")" && pwd)

docker image inspect "$image_ref" >/dev/null 2>&1 || fail "$image_ref is not a local image"

echo "== Layers"
if docker image inspect --format '{{range .RootFS.Layers}}{{println .}}{{end}}' "$image_ref" | grep . \
    | diff -u "$release_dir/expected-base-layers.txt" -; then
    echo "PASS: the 25 layers of the deployed 4.35-6 image"
else
    fail "$image_ref does not have exactly the deployed image's layers"
fi

echo "== Configuration"
created=$(docker image inspect --format '{{.Created}}' "$image_ref")
[ "$created" = "$BASE_CREATED" ] || fail "created $created, expected $BASE_CREATED"
cmd=$(docker image inspect --format '{{json .Config}}' "$image_ref" | jq -c '.Cmd')
[ "$cmd" = '["/sbin/my_init"]' ] || fail "command $cmd, expected [\"/sbin/my_init\"]"
echo "PASS: created $created, command $cmd"

echo "== Registry tag must not exist"
registry=${BASE_TAG_REF%%/*}
repository_and_tag=${BASE_TAG_REF#*/}
repository=${repository_and_tag%:*}
tag=${repository_and_tag##*:}

registry_auth=$(jq -r --arg host "$registry" '.auths[$host].auth // empty' "$HOME/.docker/config.json")
[ -n "$registry_auth" ] || fail "no stored credentials for $registry"

registry_body=$(mktemp)
trap 'rm -f "$registry_body"' EXIT

registry_get() {
    printf 'header = "Authorization: Basic %s"\n' "$registry_auth" \
        | curl -sS -K - -o "$registry_body" -w '%{http_code}' \
            -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
            "https://$registry$1"
}

api_status=$(registry_get /v2/) || fail "registry unreachable"
[ "$api_status" = 200 ] || fail "registry API check returned HTTP $api_status"

manifest_status=$(registry_get "/v2/$repository/manifests/$tag") || fail "registry unreachable"
case "$manifest_status" in
    200) fail "$BASE_TAG_REF already exists in the registry" ;;
    404)
        grep -q 'MANIFEST_UNKNOWN' "$registry_body" \
            || fail "registry returned 404 without MANIFEST_UNKNOWN: $(head -c 300 "$registry_body")"
        echo "$BASE_TAG_REF is not in the registry yet"
        ;;
    *) fail "registry returned HTTP $manifest_status for $BASE_TAG_REF" ;;
esac

echo "PASS: $image_ref can be published as $BASE_TAG_REF"
