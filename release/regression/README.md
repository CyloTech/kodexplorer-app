# Regression checks

Each `*.sh` file here is mounted read-only into the image at
`/release/regression/` and run with `sh`. It must exit 0 only when the issue
it covers is fixed. Add one for every patch in `php72-patches/`.

`lib/` holds shared helpers and is not run directly. `lib/fpm.sh` starts a
private php-fpm7.2 master with a single static worker on 127.0.0.1, so
consecutive requests reach the same process, and `lib/fcgi.php` sends
FastCGI requests to it the way nginx does.

| Check | Patch |
| --- | --- |
| `cve-2026-109618-oom.sh` | `0001-CVE-2026-109618-109619.patch` (out-of-memory handling, multipart headers) |
| `cve-2026-109619-state.sh` | `0001-CVE-2026-109618-109619.patch` (state reset, session upload progress) |

These files are copied from CyloTech/rutorrent-app php72-multipart-fix
(e5de63e2). `lib/fpm.sh` differs in two places. This image has no `nginx`
user, so the private pool runs as `www-data` when `nginx` does not exist. The private
php-fpm7.2 master starts with `-d zend.assertions=1`: Ubuntu's production
php.ini sets -1, and the CVE-2026-109619 check relies on
`PHP_VALUE=zend.assertions=-1` warning before request startup.
