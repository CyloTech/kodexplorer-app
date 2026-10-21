# Helpers sourced by the regression checks. They run inside the image as
# root with no network, start a private php-fpm7.2 master with one static
# worker on 127.0.0.1, and drive it with lib/fcgi.php like nginx would.
#
# One worker means consecutive requests are served by the same process, so
# state left behind by one request is seen by the next one.

regression_lib=/release/regression/lib

fail() {
    echo "FAIL: $*" >&2
    if [ -n "${fpm_dir:-}" ] && [ -f "$fpm_dir/fpm.log" ]; then
        echo "--- php-fpm log" >&2
        tail -n 40 "$fpm_dir/fpm.log" >&2
    fi
    exit 1
}

# fpm_start <port> [php_admin_value lines...]
# Creates $fpm_dir with a document root ($fpm_root) and starts php-fpm7.2.
fpm_start() {
    fpm_port=$1
    shift
    fpm_dir=$(mktemp -d /tmp/regression-fpm.XXXXXX)
    fpm_root=$fpm_dir/www
    mkdir -p "$fpm_root" "$fpm_dir/sessions" "$fpm_dir/tmp"
    chmod 0777 "$fpm_dir/sessions" "$fpm_dir/tmp"
    chmod 0755 "$fpm_dir" "$fpm_root"
    # The ruTorrent image runs its pool as nginx; images without that user
    # (KODExplorer, ubuntu-lep) run theirs as www-data.
    fpm_user=nginx
    id -u "$fpm_user" >/dev/null 2>&1 || fpm_user=www-data
    {
        echo '[global]'
        echo "error_log = $fpm_dir/fpm.log"
        echo "pid = $fpm_dir/fpm.pid"
        echo 'log_level = notice'
        echo '[regression]'
        echo "user = $fpm_user"
        echo "group = $fpm_user"
        echo "listen = 127.0.0.1:$fpm_port"
        echo 'pm = static'
        echo 'pm.max_children = 1'
        echo 'catch_workers_output = yes'
        echo 'clear_env = no'
        echo "php_admin_value[session.save_path] = $fpm_dir/sessions"
        echo "php_admin_value[upload_tmp_dir] = $fpm_dir/tmp"
        for line in "$@"; do
            echo "php_admin_value[${line%%=*}] = ${line#*=}"
        done
    } > "$fpm_dir/fpm.conf"

    printf '%s' '<?php echo getmypid();' > "$fpm_root/pid.php"
    chmod -R a+rX "$fpm_root"

    php-fpm7.2 --nodaemonize --fpm-config "$fpm_dir/fpm.conf" >"$fpm_dir/master.out" 2>&1 &
    fpm_master=$!
    trap 'fpm_stop' EXIT

    attempt=0
    while ! fpm_pid >/dev/null 2>&1; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 50 ] || fail "php-fpm7.2 did not start: $(cat "$fpm_dir/master.out")"
        sleep 0.2
    done
}

fpm_stop() {
    if [ -n "${fpm_master:-}" ]; then
        kill "$fpm_master" 2>/dev/null || true
        wait "$fpm_master" 2>/dev/null || true
        fpm_master=
    fi
}

# fcgi <script> <body-file|-> [NAME=VALUE ...]: request a script from $fpm_root
fcgi() {
    fcgi_script=$1
    shift
    fcgi_body=$1
    shift
    php7.2 -n "$regression_lib/fcgi.php" 127.0.0.1 "$fpm_port" "$fcgi_body" \
        "SCRIPT_FILENAME=$fpm_root/$fcgi_script" "SCRIPT_NAME=/$fcgi_script" \
        "REQUEST_URI=/$fcgi_script" "DOCUMENT_ROOT=$fpm_root" \
        "SERVER_PROTOCOL=HTTP/1.1" "GATEWAY_INTERFACE=CGI/1.1" \
        "SERVER_NAME=localhost" "SERVER_PORT=80" "REMOTE_ADDR=127.0.0.1" \
        "$@"
}

# Prints the PID of the worker that serves the next request.
fpm_pid() {
    fcgi pid.php - REQUEST_METHOD=GET
}

# Waits until the master has replaced a worker that exited.
fpm_wait_respawn() {
    attempt=0
    while ! new_pid=$(fpm_pid 2>/dev/null) || [ -z "$new_pid" ] || [ "$new_pid" = "$1" ]; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 50 ] || fail "worker $1 was not replaced"
        sleep 0.2
    done
    echo "$new_pid"
}

# wait_for_log <text> <label>: the master logs worker output asynchronously
wait_for_log() {
    attempt=0
    while ! grep -qF -- "$1" "$fpm_dir/fpm.log"; do
        attempt=$((attempt + 1))
        [ "$attempt" -lt 50 ] || fail "$2: '$1' never appeared in the php-fpm log"
        sleep 0.1
    done
}

assert_contains() {
    case "$1" in
        *"$2"*) ;;
        *) fail "$3: expected '$2' in: $(printf '%s' "$1" | head -c 600)" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "$3: unexpected '$2' in: $(printf '%s' "$1" | head -c 600)" ;;
        *) ;;
    esac
}

# multipart_part <file> <name> <value> [filename]
multipart_boundary=----------------------------regression7224
multipart_part() {
    if [ $# -ge 4 ]; then
        printf '%s\r\nContent-Disposition: form-data; name="%s"; filename="%s"\r\nContent-Type: text/plain\r\n\r\n%s\r\n' \
            "--$multipart_boundary" "$2" "$4" "$3" >> "$1"
    else
        printf '%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n' \
            "--$multipart_boundary" "$2" "$3" >> "$1"
    fi
}

multipart_end() {
    printf '%s\r\n' "--$multipart_boundary--" >> "$1"
}

multipart_type="CONTENT_TYPE=multipart/form-data; boundary=$multipart_boundary"
