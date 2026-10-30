# Kodbox 1.70.03: the deployed kodbox:1.70.02-2 image with Kodbox 1.70.03 in
# /kod_sources.
#
# The base is the exact image every 1.70.02-2 instance runs, pinned by digest,
# so PHP 8.3, the packages, the configuration, the install scripts, the
# installed-callback service, CMD and environment stay as they were. Only
# /kod_sources changes: it is upstream Kodbox 1.70.03 with the Appbox changes,
# CyloTech/kodbox branch appbox-1.70.03, pinned by commit. kod.sh copies it
# into public_html on the first start of each new container and keeps
# config/setting_user.php and the data volume, as for earlier releases.
#
# release/verify-image.sh is the release gate.

FROM repo.cylo.net/kodbox@sha256:60e5b07d8db4e8bafe723c856f374a8c11884fb4c83349f52c2e56293f564d51

RUN rm -rf /kod_sources
ADD https://github.com/CyloTech/kodbox.git#a48bafa0b601731e0b16f15f5f696598edeb36eb /kod_sources

LABEL net.cylo.kodbox-release="1.70.03"
