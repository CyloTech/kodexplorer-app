# KODExplorer 4.35-7: the deployed 4.35-6 image (Ubuntu 18.04, built
# 2020-09-29) with its php7.2 packages replaced by a local rebuild.
#
# Stage 1 rebuilds Ubuntu's last public bionic php7.2 source package with the
# patches in php72-patches/. It is byte-for-byte the php72-build stage of
# CyloTech/rutorrent-app (branch php72-multipart-fix, e5de63e2), and
# php72-patches/ must stay identical to rutorrent-app's, so both images carry
# the same PHP build. Stage 2 is the deployed 4.35-6 image with its php7.2
# packages replaced, so the PHP ABI, the PECL extensions, the configuration
# and 30_installer.sh stay as they were.
#
# KODEXPLORER_BASE is the deployed image (image ID
# sha256:683ec9821a2ffa98373fc52389fde1402714f9f3a369c1e1a684c31cf91027c8).
# It was no longer in the registry under any tag, so it was saved from a node
# (Cylo 7050 on cylo08), checked with release/verify-base.sh and re-published
# as repo.cylo.net/kodexplorer:4.35-6-bionic-base, whose manifest digest is
# pinned here. release/verify-image.sh checks that the result sits on exactly
# that image's 25 layers.
#
# The only other change is scripts/kod.sh: on a recreated container it keeps
# the KODExplorer 4.x code already in public_html instead of resetting it to
# the 4.40 code in Git (15 instances run 4.51 to 4.56 from the in-app updater).

ARG PHP72_SOURCE_VERSION=7.2.24-0ubuntu0.18.04.17
ARG PHP72_LOCAL_SUFFIX=+cylo2
ARG KODEXPLORER_BASE=repo.cylo.net/kodexplorer@sha256:5bd139e6840bcf3db09c27a11a6deae1db15398d90d25ae9e9c4c6ec59eac7af

FROM ubuntu:18.04@sha256:152dc042452c496007f07ca9127571cb9c29697f42acbfad72324b2bb2e43c98 AS php72-build
ARG PHP72_SOURCE_VERSION
ARG PHP72_LOCAL_SUFFIX
ENV DEBIAN_FRONTEND=noninteractive DEBFULLNAME="Appbox build" DEBEMAIL=build@localhost

RUN sed -i 's/^# deb-src/deb-src/' /etc/apt/sources.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends build-essential devscripts dpkg-dev fakeroot quilt \
    && apt-get build-dep -y "php7.2=${PHP72_SOURCE_VERSION}"

WORKDIR /build
RUN apt-get source --only-source "php7.2=${PHP72_SOURCE_VERSION}"
COPY php72-patches/ /build/php72-patches/

# Append each local patch to the package's quilt series and fail the build
# if any of them does not apply cleanly.
RUN cd php7.2-7.2.24 \
    && export QUILT_PATCHES=debian/patches \
    && for patch in /build/php72-patches/*.patch; do \
           [ -e "$patch" ] || continue; \
           cp "$patch" debian/patches/; \
           basename "$patch" >> debian/patches/series; \
           quilt push "$(basename "$patch")"; \
       done \
    && dch --newversion "${PHP72_SOURCE_VERSION}${PHP72_LOCAL_SUFFIX}" --distribution bionic-security \
           "Appbox: apply local security patches from php72-patches/." \
    && DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -uc -us

FROM ${KODEXPLORER_BASE}
ARG PHP72_SOURCE_VERSION
ARG PHP72_LOCAL_SUFFIX
ARG KODEXPLORER_BASE

COPY --from=php72-build /build/*.deb /tmp/php72/

# Replace exactly the installed packages built from the php7.2 source package
# (29 in the deployed image, including php7.2-fpm, php7.2-cli,
# libapache2-mod-php7.2 and php7.2-dev). Conffiles the image already has are
# kept.
RUN set -eu; \
    cd /tmp/php72; \
    pkgs=$(dpkg-query -W -f='${db:Status-Abbrev}|${Package}|${Source}\n' \
        | awk -F'|' '{ split($3, src, " "); if (src[1] == "") src[1] = $2 } $1 ~ /^ii/ && src[1] == "php7.2" {print $2}'); \
    [ -n "$pkgs" ] || { echo "no php7.2 packages installed" >&2; exit 1; }; \
    debs=; \
    for pkg in $pkgs; do \
        deb=$(ls ./"${pkg}_${PHP72_SOURCE_VERSION}${PHP72_LOCAL_SUFFIX}"_*.deb); \
        debs="$debs $deb"; \
    done; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold $debs; \
    rm -rf /tmp/php72 /var/lib/apt/lists/*; \
    php-fpm7.2 -t

COPY --chmod=0755 scripts/kod.sh /scripts/install/kod.sh

LABEL net.cylo.php72-version="${PHP72_SOURCE_VERSION}${PHP72_LOCAL_SUFFIX}" \
      net.cylo.base-image="${KODEXPLORER_BASE}"
