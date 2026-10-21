# php7.2 patches

Each `*.patch` file here is added to Ubuntu's php7.2 quilt series in name
order, so prefix them with a number (`0001-...`). Patches must apply to the
`php7.2-7.2.24` source tree with `-p1`; the build fails if one does not.

Bump `PHP72_LOCAL_SUFFIX` in the Dockerfile (`+cylo1`, `+cylo2`, ...) whenever
the set of patches changes, and add a regression check under
`release/regression/` for the issue each patch fixes.

## Patches

- `0001-CVE-2026-109618-109619.patch`: PHP 7.2 port of php-src's minimal
  mitigation for CVE-2026-109618 and CVE-2026-109619 (Canonical's php8.1
  8.1.2-1ubuntu2.28 patch, php-src 1d7dec178a0). The patch header maps each
  8.1 hunk to 7.2. Behaviour changes: memory exhaustion ends the PHP process
  (an FPM worker exits with status 1, the client gets no response, and
  shutdown functions do not run; the message is in the FPM log), and
  `session.upload_progress.enabled` no longer has any effect.
