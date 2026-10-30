# Kodbox 1.70.03: the deployed kodbox:1.70.02-2 image with Kodbox 1.70.03 in
# /kod_sources.
#
# The base is the exact image every 1.70.02-2 instance runs, pinned by digest,
# so PHP 8.3, the packages, the configuration, CMD and environment stay as they
# were. /kod_sources is replaced by upstream Kodbox 1.70.03 with the Appbox
# changes, CyloTech/kodbox branch appbox-1.70.03, pinned by commit. kod.sh
# copies it into public_html on the first start of each new container and
# keeps config/setting_user.php and the data volume, as for earlier releases.
#
# The install scripts and the installed-callback service are copied from this
# repository as in 1.70.02-2; they are unchanged, so the files are the ones the
# base already holds.
#
# release/verify-image.sh is the release gate.

FROM repo.cylo.net/kodbox@sha256:60e5b07d8db4e8bafe723c856f374a8c11884fb4c83349f52c2e56293f564d51

RUN rm -rf /kod_sources
ADD https://github.com/CyloTech/kodbox.git#a48bafa0b601731e0b16f15f5f696598edeb36eb /kod_sources

COPY --chmod=755 scripts/kod.sh /scripts/install/kod.sh
COPY --chmod=644 scripts/kodbox-install-step.php /scripts/install/kodbox-install-step.php
COPY --chmod=644 scripts/kodbox-install-check.php /scripts/install/kodbox-install-check.php
COPY --chmod=755 scripts/30_installer.sh /etc/my_init.d/30_installer.sh

# Appbox installed callback: 30_installer.sh only marks it pending and this
# runit service sends it after my_init.d, so it can never block startup.
COPY scripts/appbox-installed-callback /usr/local/bin/appbox-installed-callback
COPY scripts/appbox-callback-run /etc/service/appbox-callback/run
RUN chmod 755 /usr/local/bin/appbox-installed-callback /etc/service/appbox-callback/run

LABEL net.cylo.kodbox-release="1.70.03"
