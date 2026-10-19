# Kodbox 1.70.02-2: the deployed kodbox:1.70.02-1 image with a new first-start
# installer.
#
# The base is the exact image every 1.70.02-1 instance runs, pinned by digest,
# so Kodbox (/kod_sources), PHP 8.3 with the 21 October 2026 fixes, the
# packages, the configuration, CMD and environment stay as they were. Only the
# install scripts change: kod.sh installs Kodbox through index.php's
# command-line entry point before nginx and PHP-FPM start, instead of over HTTP
# through the public domain once they are running.
#
# release/verify-image.sh is the release gate.

FROM repo.cylo.net/kodbox@sha256:8e6cd075d8e360f5b0d8832b077ee315c2fd9544fc795e7be96181c227bd16ed

COPY --chmod=755 scripts/kod.sh /scripts/install/kod.sh
COPY --chmod=644 scripts/kodbox-install-step.php /scripts/install/kodbox-install-step.php
COPY --chmod=644 scripts/kodbox-install-check.php /scripts/install/kodbox-install-check.php
COPY --chmod=755 scripts/30_installer.sh /etc/my_init.d/30_installer.sh

# Appbox installed callback: 30_installer.sh only marks it pending and this
# runit service sends it after my_init.d, so it can never block startup.
COPY scripts/appbox-installed-callback /usr/local/bin/appbox-installed-callback
COPY scripts/appbox-callback-run /etc/service/appbox-callback/run
RUN chmod 755 /usr/local/bin/appbox-installed-callback /etc/service/appbox-callback/run

LABEL net.cylo.kodbox-release="1.70.02-2"
