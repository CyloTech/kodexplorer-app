#!/bin/bash
# Kodbox setup, run by 30_installer.sh on the first start of every container
# (new install, reinstall and update; restarts skip it).
#
# Kodbox is installed with its own installer steps (install/index/save, the
# steps install/index/auto runs) through index.php's command-line entry point,
# as the appbox user, before nginx and PHP-FPM run. Nothing serves HTTP until
# my_init.d has finished, so the web installer is never reachable on a new
# instance: earlier images installed over HTTP through the public domain, and
# whoever reached it first could create the administrator.
#
# Persistent volumes that already hold an installation (config/setting_user.php
# and data/system/install.lock) are kept as they are: no install step runs and
# the data and administrator are unchanged.
#
# Exits non-zero unless Kodbox is installed afterwards; 30_installer.sh then
# stops without marking the installed callback, my_init stops the container and
# the web server never starts.
#
# ADMIN_PASS is never traced or printed. Do not add `set -x`.

public_html=/home/appbox/public_html
data_dir=/home/appbox/data
settings_file="$public_html/config/setting_user.php"
install_lock="$data_dir/system/install.lock"
install_step="$INST_SCRIPTS/kodbox-install-step.php"
install_check="$INST_SCRIPTS/kodbox-install-check.php"

fail() {
    echo "kod.sh: $*" >&2
    exit 1
}

# Run a PHP helper as the appbox user, the user PHP-FPM runs Kodbox as.
as_appbox() {
    setpriv --reuid=appbox --regid=appbox --init-groups -- "$@"
}

# One install step (db or user). Kodbox answers with its JSON result; the step
# passed only when it says "code": true.
run_install_step() {
    local step=$1 output
    output=$(cd "$public_html" && as_appbox php "$install_step" "$step" 2>&1)
    local rc=$?
    # Kodbox does not echo the password; redact it anyway before logging.
    echo "Kodbox install step '$step': ${output//"$KODBOX_ADMIN_PASS"/[password]}"
    [[ "$rc" -eq 0 ]] || return 1
    grep -Eq '"code": ?true' <<<"$output" && ! grep -Eq '"code": ?false' <<<"$output"
}

[[ -d /kod_sources ]] || fail "/kod_sources is missing"

if [ -d "$public_html/KODExplorer" ]; then
    rm -rf "$public_html/KODExplorer"
fi

# Back up user settings if they exist
if [ -f "$settings_file" ]; then
    cp -R "$settings_file" /tmp/setting_user.php || fail "cannot back up config/setting_user.php"
fi

if [ ! -f "$public_html/index.php" ]; then
    cp -R /kod_sources/* "$public_html/" || fail "cannot copy Kodbox into $public_html"
else
    rm -rf "$public_html"/.[!.]* "$public_html"/..?*
    rm -rf "$public_html"/*
    cp -R /kod_sources/* "$public_html/" || fail "cannot copy Kodbox into $public_html"
fi

if [ ! -d "$data_dir/system" ]; then
    mv "$public_html/data/system" "$data_dir/" || fail "cannot create $data_dir/system"
fi

if [ -f "/tmp/setting_user.php" ]; then
    cp -R /tmp/setting_user.php "$settings_file" || fail "cannot restore config/setting_user.php"
fi

chmod -R 777 "$data_dir"
chmod -R 777 "$public_html"

chown -R appbox:appbox /home/appbox/

if [[ -f "$settings_file" && -f "$install_lock" ]]; then
    echo "Kodbox is already installed: keeping the existing data and administrator"
else
    [[ -n "${ADMIN_PASS:-}" ]] || fail "ADMIN_PASS is not set; cannot create the Kodbox administrator"
    export KODBOX_ADMIN_USER="${ADMIN_USER:-admin}"
    export KODBOX_ADMIN_PASS="$ADMIN_PASS"
    if [[ ! -f "$settings_file" ]]; then
        echo "Installing Kodbox: creating the database and the administrator '$KODBOX_ADMIN_USER'"
        if ! run_install_step db || ! run_install_step user \
            || ! as_appbox php "$install_check" "$KODBOX_ADMIN_USER"; then
            # Remove the half-written configuration so the next start installs
            # from scratch instead of finding a database without an
            # administrator.
            rm -f "$settings_file" "$install_lock"
            unset KODBOX_ADMIN_PASS
            fail "Kodbox installation failed"
        fi
    else
        # config/setting_user.php without install.lock: Kodbox serves its
        # installer in this state and lets anyone reset administrator 1. Finish
        # the administrator step here instead (Kodbox sets administrator 1's
        # password, or creates it if it does not exist, and writes
        # install.lock); the existing database is kept.
        echo "Kodbox has a database but no install.lock: setting the administrator '$KODBOX_ADMIN_USER' from the Appbox password"
        if ! run_install_step user || ! as_appbox php "$install_check" "$KODBOX_ADMIN_USER"; then
            unset KODBOX_ADMIN_PASS
            fail "Kodbox administrator step failed"
        fi
    fi
    unset KODBOX_ADMIN_PASS
fi

[[ -f "$settings_file" ]] || fail "config/setting_user.php is missing after setup"
[[ -f "$install_lock" ]] || fail "install.lock is missing after setup"
echo "Kodbox is installed"

# Disable Guest & Demo Logins
rm -fr /home/appbox/data/User/guest
rm -fr /home/appbox/data/User/demo
rm -rf /kod_sources
rm -rf /code_sources
