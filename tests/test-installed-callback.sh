#!/usr/bin/env bash
# Tests for the Appbox installed callback, run against a local mock API (needs
# bash, curl and python3; no Docker):
#   - scripts/appbox-installed-callback retries network errors, 408, 429 and
#     5xx, stops after one try on any other status, sends CALLBACK_TOKEN in
#     X-Cylo-Callback-Token and never logs the callback token;
#   - the appbox-callback runit service (scripts/appbox-callback-run) sends a
#     pending callback once, clears the flag and then idles;
#   - 30_installer.sh finishes straight away, marks the callback pending on
#     first boot after kod.sh succeeded, before /etc/installer30_completed,
#     and never calls the API itself; the Dockerfile installs the helper and
#     service.
#
# Usage: tests/test-installed-callback.sh
set -u

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
helper="${repo_root}/scripts/appbox-installed-callback"
token_id='999?callback_token=querytoken0123456789'
header_token='headertoken0123456789'

# Answers GET with 200 (readiness) and each POST with the next status from a
# comma-separated list, logging what it received.
mock_server='
import http.server, json, os, sys
port, codes, log = int(sys.argv[1]), [int(c) for c in sys.argv[2].split(",")], sys.argv[3]
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
    def do_POST(self):
        seen = sum(1 for _ in open(log)) if os.path.exists(log) else 0
        code = codes[min(seen, len(codes) - 1)]
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "code": code, "body": body,
                                "token": self.headers.get("X-Cylo-Callback-Token", "")}) + "\n")
        self.send_response(code)
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", port), Handler).serve_forever()
'

failures=0
work=""
server=""

pass() { echo "ok   $*"; }
fail() {
    echo "FAIL $*"
    [[ -f "${work}/output" ]] && sed 's/^/     /' "${work}/output"
    failures=$((failures + 1))
}

start_mock() {
    work="$(mktemp -d)"
    port=$((20000 + RANDOM % 20000))
    python3 -c "${mock_server}" "${port}" "$1" "${work}/requests" &
    server=$!
    for _ in $(seq 1 50); do
        curl -s -o /dev/null "http://127.0.0.1:${port}/" && return 0
        sleep 0.1
    done
    echo "mock API did not start" >&2
    exit 2
}

stop_mock() {
    kill "${server}" 2>/dev/null
    wait "${server}" 2>/dev/null
    rm -rf "${work}"
}

# Run a command, killing it (exit 124) if it is still running after $1 seconds,
# so a callback that never stops fails the test instead of hanging it.
run_limited() {
    local limit=$1 pid ticks=0
    shift
    "$@" &
    pid=$!
    while kill -0 "${pid}" 2>/dev/null && [[ "${ticks}" -lt $((limit * 10)) ]]; do
        sleep 0.1
        ticks=$((ticks + 1))
    done
    if kill -0 "${pid}" 2>/dev/null; then
        kill "${pid}" 2>/dev/null
        wait "${pid}" 2>/dev/null
        return 124
    fi
    wait "${pid}"
}

request_count() { cat "${work}/requests" 2>/dev/null | wc -l | tr -d ' '; }
token_logged() { grep -cE 'querytoken|headertoken' "${work}/output"; }

# --- helper ------------------------------------------------------------------

helper_case() {
    local codes=$1 want_exit=$2 want_requests=$3
    shift 3
    start_mock "${codes}"
    run_limited 20 env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
        APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
        APPBOX_CALLBACK_RETRY_DELAY=1 \
        "$@" "${helper}" >"${work}/output" 2>&1
    local rc=$? requests leaked
    requests=$(request_count)
    leaked=$(token_logged)
    if [[ "${rc}" == "${want_exit}" && "${requests}" == "${want_requests}" && "${leaked}" == 0 ]]; then
        pass "helper codes=${codes} exit=${rc} requests=${requests}"
    else
        fail "helper codes=${codes} exit=${rc}/${want_exit} requests=${requests}/${want_requests} token_logged=${leaked}"
    fi
    stop_mock
}

helper_case 200 0 1
helper_case 401 1 1
helper_case 404 1 1
helper_case 409 1 1
helper_case 422 1 1
helper_case 503,502,200 0 3
helper_case 429,408,204 0 3
helper_case 500,401 1 2
helper_case 200 0 0 SKIP_APPBOX_CALLBACK=1

# Network errors are retried: nothing listens on the port for the first try.
work="$(mktemp -d)"
port=$((20000 + RANDOM % 20000))
(
    sleep 1.5
    exec python3 -c "${mock_server}" "${port}" 200 "${work}/requests"
) &
server=$!
run_limited 20 env INSTANCE_ID="${token_id}" APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    APPBOX_CALLBACK_RETRY_DELAY=1 "${helper}" >"${work}/output" 2>&1
rc=$?
if [[ "${rc}" == 0 ]] && grep -q 'HTTP 000, retrying' "${work}/output" && [[ "$(request_count)" == 1 ]]; then
    pass "helper retries a network error"
else
    fail "helper network error exit=${rc} requests=$(request_count)"
fi
stop_mock

# An invalid APPBOX_CALLBACK_RETRY_DELAY falls back to the 5s default.
start_mock 503,200
run_limited 20 env INSTANCE_ID="${token_id}" APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    APPBOX_CALLBACK_RETRY_DELAY='1;x' "${helper}" >"${work}/output" 2>&1
rc=$?
if [[ "${rc}" == 0 ]] && grep -q 'retrying in 5s' "${work}/output" && [[ "$(request_count)" == 2 ]]; then
    pass "helper ignores an invalid retry delay"
else
    fail "helper invalid retry delay exit=${rc} requests=$(request_count)"
fi
stop_mock

# Token header, query string and optional body reach the API.
start_mock 200
run_limited 20 env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
    APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" \
    "${helper}" '{"custom_fields":[{"key":"ADMIN_PANEL","value":"https://example.test/"}]}' \
    >"${work}/output" 2>&1
if python3 - "${work}/requests" "${header_token}" <<'PY'
import json, sys
req = json.loads(open(sys.argv[1]).readline())
assert req["path"] == "/v1/apps/installed/999?callback_token=querytoken0123456789", req
assert req["token"] == sys.argv[2], req
assert json.loads(req["body"])["custom_fields"][0]["key"] == "ADMIN_PANEL", req
PY
then
    pass "helper sends path, X-Cylo-Callback-Token and body"
else
    fail "helper request contents"
fi
stop_mock

service="${repo_root}/scripts/appbox-callback-run"

# --- appbox-callback runit service ---------------------------------------------

# Run a copy of the runit run script with the flag and helper pointed into the
# scratch directory and `exec sleep infinity` replaced by `echo paused`.
#   pending: yes (first boot marked the callback pending) or no (restart).
service_case() {
    local codes=$1 pending=$2 want_requests=$3
    start_mock "${codes}"
    local sandbox="${work}/run"
    sed -e "s|/etc/appbox_callback_pending|${work}/callback_pending|g" \
        -e "s|/usr/local/bin/appbox-installed-callback|${helper}|" \
        -e 's|^exec sleep infinity$|echo paused|' \
        "${service}" >"${sandbox}"
    chmod +x "${sandbox}"
    [[ "${pending}" == yes ]] && touch "${work}/callback_pending"
    run_limited 20 env INSTANCE_ID="${token_id}" CALLBACK_TOKEN="${header_token}" \
        APPBOX_CALLBACK_BASE="http://127.0.0.1:${port}" APPBOX_CALLBACK_RETRY_DELAY=1 \
        "${sandbox}" >"${work}/output" 2>&1
    local rc=$? requests
    requests=$(request_count)
    if [[ "${rc}" == 0 && "${requests}" == "${want_requests}" && ! -f "${work}/callback_pending" ]] \
        && grep -q '^paused$' "${work}/output" && [[ "$(token_logged)" == 0 ]]; then
        pass "service pending=${pending} codes=${codes}: requests=${requests}, flag cleared, service idles"
    else
        fail "service pending=${pending} codes=${codes}: exit=${rc} requests=${requests}/${want_requests}"
    fi
    stop_mock
}

service_case 401 yes 1
service_case 503,200 yes 2
service_case 200 no 0

# --- my_init.d installer -----------------------------------------------------------

# Run a sandboxed copy of ${inst_script}: the ${inst_sed} expressions (where
# @WORK@ stands for the scratch directory) point its paths into the scratch
# directory, replace its sub-scripts with ${work}/stub (which exits with
# stub_rc) and drop clean-up lines. The commands in ${inst_stubs} are stubs
# that record their arguments, and curl answers any api.cylo.* URL with a 401, so an
# installer that still waited for the callback would hang. Nothing reaches a
# real host. inst_state <state> (optional, defined by the repo part) prepares
# the state in ${work} first.
inst_stubs=(apt apt-get dpkg wget chown)
installer_case() {
    local name=$1 state=$2 stub_rc=$3 want_rc=$4 want_flag=$5
    shift 5
    start_mock 200
    local sandbox="${work}/installer.sh" cmd
    mkdir -p "${work}/bin"
    for cmd in "${inst_stubs[@]}"; do
        printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\n' "${cmd}" "${work}" >"${work}/bin/${cmd}"
    done
    printf '#!/bin/sh\necho "curl $*" >>"%s/calls"\ncase "$*" in *api.cylo.*) echo "HTTP/2 401"; exit 22 ;; esac\n' \
        "${work}" >"${work}/bin/curl"
    printf '#!/bin/sh\nexit %s\n' "${stub_rc}" >"${work}/stub"
    chmod +x "${work}/bin/"* "${work}/stub"
    if declare -F inst_state >/dev/null; then
        (cd "${work}" && inst_state "${state}")
    fi
    sed -e "s|/etc/appbox_callback_pending|${work}/callback_pending|g" \
        "${inst_sed[@]//@WORK@/${work}}" "${inst_script}" >"${sandbox}"
    # Refuse to run if any rm still targets a path outside the scratch dir.
    if grep -E '(^|[[:space:];&|(])rm[[:space:]]' "${sandbox}" \
        | grep -oE '[[:space:]]/[^[:space:]]*' | grep -vqF -- " ${work}"; then
        fail "installer ${name}: could not sandbox the clean-up commands"
        stop_mock
        return
    fi
    run_limited 10 env PATH="${work}/bin:${PATH}" INSTANCE_ID="${token_id}" \
        CALLBACK_TOKEN="${header_token}" "$@" bash "${sandbox}" >"${work}/output" 2>&1
    local rc=$? flag=no
    [[ -f "${work}/callback_pending" ]] && flag=yes
    if [[ "${rc}" == "${want_rc}" && "${flag}" == "${want_flag}" ]] \
        && ! grep -q 'apps/installed' "${work}/calls" 2>/dev/null \
        && [[ "$(request_count)" == 0 && "$(token_logged)" == 0 ]]; then
        pass "installer ${name}: exit=${rc}, callback pending=${flag}, no callback sent"
    else
        fail "installer ${name}: exit=${rc}/${want_rc} pending=${flag}/${want_flag} callback_calls=$(grep -c 'apps/installed' "${work}/calls" 2>/dev/null)"
    fi
    stop_mock
}

# The pending flag must be set before the configured marker, so a crash
# between the two cannot lose the callback.
flag_before_marker() {
    local file=$1 marker=$2 flag_line marker_line
    flag_line=$(grep -n 'touch /etc/appbox_callback_pending' "${file}" | tail -1 | cut -d: -f1)
    marker_line=$(grep -n "touch ${marker}" "${file}" | tail -1 | cut -d: -f1)
    if [[ -n "${flag_line}" && -n "${marker_line}" && "${flag_line}" -lt "${marker_line}" ]]; then
        pass "$(basename "${file}") marks the callback pending before ${marker}"
    else
        fail "$(basename "${file}") does not mark the callback pending before ${marker}"
    fi
}

inst_script="${repo_root}/scripts/30_installer.sh"
inst_sed=(
    -e 's|/etc/installer30_completed|@WORK@/installer30_completed|g'
    -e 's|\$INST_SCRIPTS/kod.sh|@WORK@/stub|'
    -e 's|/home/appbox|@WORK@/home|g'
    -e 's|/run/php|@WORK@/run/php|g'
    -e 's|^\([[:space:]]*\)chmod 777 /run$|\1:|'
    -e '/^[[:space:]]*rm -fr \/sources$/d'
    -e '/^[[:space:]]*rm -rf \/var\/lib\/apt\/lists/d'
)
inst_state() {
    [[ "$1" == restart ]] && touch installer30_completed
    return 0
}
installer_case first-boot fresh 0 0 yes
installer_case kod-sh-failed fresh 1 1 no
installer_case restart restart 0 0 no
flag_before_marker "${inst_script}" /etc/installer30_completed

if grep -q '^COPY scripts/appbox-installed-callback /usr/local/bin/appbox-installed-callback$' "${repo_root}/Dockerfile" \
    && grep -q '^COPY scripts/appbox-callback-run /etc/service/appbox-callback/run$' "${repo_root}/Dockerfile"; then
    pass "Dockerfile installs the helper and the runit service"
else
    fail "Dockerfile does not install the helper and the runit service"
fi

exit "${failures}"
