#!/bin/bash
# Build KODExplorer 4.35-7 on the Appbox builder from the pushed commit, run
# the release gate and push only if it passes.
#
# Usage (from a clean checkout of this branch, HEAD pushed to origin):
#   release/builder-release.sh
#
# The build context is `git archive HEAD` of the repository, checked by
# sha256 on the builder. The image is built as repo.cylo.net/kodexplorer:4.35-7
# with --no-cache, gated with release/verify-image.sh and pushed; the pushed
# digest is printed. Nothing is pushed when the gate fails.
set -euo pipefail

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

image_ref=repo.cylo.net/kodexplorer:4.35-7
slug=kodexplorer-app
tag=4.35-7
builder=appbox@builder1.builder.appboxes.co
builder_port=10112
ssh_opts=(-i /Users/rid/.ssh/appbox_ubuntuvps2_webtop -o IdentitiesOnly=yes -o BatchMode=yes
          -o ConnectTimeout=15 -o ServerAliveInterval=30 -o StrictHostKeyChecking=yes)

repo=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
[ -z "$(git -C "$repo" status --porcelain)" ] || fail "commit or stash local changes first"
commit=$(git -C "$repo" rev-parse HEAD)
branch=$(git -C "$repo" symbolic-ref --short HEAD)
case "$branch" in
    master|main) fail "refusing to build from $branch" ;;
esac
git -C "$repo" fetch -q origin "$branch"
[ "$(git -C "$repo" rev-parse FETCH_HEAD)" = "$commit" ] || fail "HEAD $commit is not the pushed origin/$branch; push it first"
echo "commit $commit is origin/$branch"

stage=$(mktemp -d "${TMPDIR:-/tmp}/cylo-app-build.XXXXXX")
remote_dir=
cleanup() {
    rm -rf "$stage"
    case "$remote_dir" in
        "/home/appbox/builds/$slug.$tag".??????)
            ssh -p "$builder_port" "${ssh_opts[@]}" "$builder" "rm -rf '$remote_dir'" \
                || echo "clean up $builder:$remote_dir by hand" >&2
            ;;
    esac
}
trap cleanup EXIT

archive="$stage/context.tgz"
git -C "$repo" archive --format=tar.gz --output="$archive" "$commit"
archive_sha=$(shasum -a 256 "$archive" | awk '{print $1}')
echo "context.tgz sha256 $archive_sha"

remote_dir=$(ssh -p "$builder_port" "${ssh_opts[@]}" "$builder" "mktemp -d '/home/appbox/builds/$slug.$tag.XXXXXX'")
case "$remote_dir" in
    "/home/appbox/builds/$slug.$tag".??????) ;;
    *) remote_dir=; fail "unexpected builder directory" ;;
esac
echo "builder directory $remote_dir"
scp -q -P "$builder_port" "${ssh_opts[@]}" "$archive" "$builder:$remote_dir/context.tgz"
ssh -p "$builder_port" "${ssh_opts[@]}" "$builder" \
    "cd '$remote_dir' && printf '%s  context.tgz\n' '$archive_sha' | sha256sum -c - && mkdir context && tar xzf context.tgz -C context"
ssh -p "$builder_port" "${ssh_opts[@]}" "$builder" \
    "cd '$remote_dir/context' && \
    docker build --no-cache --platform linux/amd64 --progress=plain -t '$image_ref' . > '$remote_dir/build.log' 2>&1 \
        || { tail -60 '$remote_dir/build.log'; exit 1; }; \
    tail -5 '$remote_dir/build.log'; \
    sh ./release/verify-image.sh '$image_ref' && \
    docker push '$image_ref' && \
    docker buildx imagetools inspect '$image_ref' | sed -n 's/^Digest: *//p'"
echo "PUSHED: $image_ref from $commit"
