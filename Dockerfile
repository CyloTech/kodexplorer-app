# Kodbox 1.70.02-1: the deployed kodbox:1.70.02 image with only its php8.3
# packages upgraded from Ubuntu noble-security.
#
# The base is the exact image every 1.70.02 instance runs, pinned by digest,
# so Kodbox (/kod_sources), the install scripts, the PHP extensions and the
# configuration stay as they were. Nothing else from this repository goes
# into the image.
#
# Release pin: set PHP83_MIN_VERSION to the noble php8.3 version that fixes
# the PHP multipart/form-data vulnerabilities announced on 21 October 2026.
# The build fails if apt cannot install at least that version, and
# release/verify-image.sh fails unless the installed version is newer than
# the last build published before the disclosure (8.3.6-0ubuntu0.24.04.12).

ARG PHP83_MIN_VERSION=8.3.6-0ubuntu0.24.04.12

FROM repo.cylo.net/kodbox@sha256:7e65783582d949e0cb8d197eb09736fb4d50e8a8eda94ff0200ceb5211925ae4
ARG PHP83_MIN_VERSION

# Upgrade exactly the installed packages built from the php8.3 source
# package (php8.3-fpm, -cli, -common, the extensions, libapache2-mod-php8.3,
# ...). Conffiles the image already has are kept.
RUN set -eu; \
    pkgs=$(dpkg-query -W -f='${db:Status-Abbrev}|${Package}|${source:Package}\n' \
        | awk -F'|' '$1 ~ /^ii/ && $3 == "php8.3" {print $2}'); \
    [ -n "$pkgs" ] || { echo "no php8.3 packages installed" >&2; exit 1; }; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --only-upgrade \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $pkgs; \
    for pkg in $pkgs; do \
        version=$(dpkg-query -W -f='${Version}' "$pkg"); \
        dpkg --compare-versions "$version" ge "$PHP83_MIN_VERSION" \
            || { echo "$pkg $version is older than $PHP83_MIN_VERSION" >&2; exit 1; }; \
    done; \
    rm -rf /var/lib/apt/lists/*; \
    php-fpm8.3 -t

LABEL net.cylo.php83-min-version="${PHP83_MIN_VERSION}"
