#!/bin/bash

set -euo pipefail
umask 077

ACTIVE_DIR="/Library/Application Support/Cold Turkey"
ACTIVE_DB="$ACTIVE_DIR/data-app.db"
ACTIVE_BROWSER_DB="$ACTIVE_DIR/data-browser.db"
ACTIVE_HELPER_DB="$ACTIVE_DIR/data-helper.db"

CT_APP_BUNDLE="/Applications/Cold Turkey Blocker.app"
CT_AGENT="/Applications/Cold Turkey Blocker.app/Contents/MacOS/Cold Turkey Blocker -agent"
CT_AGENT_BASENAME="Cold Turkey Blocker -agent"
CT_LAUNCH_AGENT_PLIST="/Library/LaunchAgents/com.getcoldturkey.blocker.agent.plist"

ENFORCER_DIR="/Library/Application Support/IronTurkeyLocker"
STATE_DIR="$ENFORCER_DIR/state"
MODE_FILE="$STATE_DIR/mode"
HASH_FILE="$STATE_DIR/last_hash"
COMPARE_OUT="$STATE_DIR/compare.out"
STATS_COMPARE_OUT="$STATE_DIR/stats_compare.out"
LOG_DIR="$ENFORCER_DIR/logs"
GOLD_DIR="$ENFORCER_DIR/gold"
GOLD_DB="$GOLD_DIR/data-app.db"
GOLD_BROWSER_DB="$GOLD_DIR/data-browser.db"
GOLD_HELPER_DB="$GOLD_DIR/data-helper.db"
LOCK_REQUEST_DIR="/private/tmp"

console_user() {
    local user_name
    user_name="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
    if [ -n "$user_name" ] && [ "$user_name" != "root" ] && [ "$user_name" != "loginwindow" ]; then
        printf '%s' "$user_name"
    else
        printf '%s' "${SUDO_USER:-root}"
    fi
}

file_metadata() {
    local path="$1"
    python3 - <<'PY' "$path"
import grp
import os
import pwd
import sys

path = sys.argv[1]
try:
    st = os.stat(path)
except FileNotFoundError:
    print("")
    raise SystemExit(0)

owner = pwd.getpwuid(st.st_uid).pw_name
group = grp.getgrgid(st.st_gid).gr_name
mode = format(st.st_mode & 0o777, "03o")
print(f"{owner}\t{group}\t{mode}")
PY
}

apply_file_metadata() {
    local path="$1"
    local metadata="$2"
    local owner group mode

    if [ -n "$metadata" ]; then
        IFS=$'\t' read -r owner group mode <<<"$metadata"
    else
        owner="$(console_user)"
        group="staff"
        mode="600"
    fi

    chown "$owner:$group" "$path" 2>/dev/null || true
    chmod "$mode" "$path" 2>/dev/null || true
}

sqlite_backup() {
    local src_db="$1"
    local dst_db="$2"

    python3 - <<'PY' "$src_db" "$dst_db"
import sqlite3
import sys

src_path, dst_path = sys.argv[1], sys.argv[2]
src = sqlite3.connect(f"file:{src_path}?mode=ro", uri=True)
dst = sqlite3.connect(dst_path)
try:
    src.backup(dst)
finally:
    dst.close()
    src.close()
PY
}

ct_agent_running() {
    pgrep -f "$(ct_agent_pattern)" >/dev/null 2>&1
}

console_user_uid() {
    local user_name
    user_name="$(console_user)"
    id -u "$user_name" 2>/dev/null || true
}

lock_request_file() {
    local uid
    uid="$(console_user_uid)"
    [ -n "$uid" ] || uid="unknown"
    printf '%s/ironturkey-lock-request.%s' "$LOCK_REQUEST_DIR" "$uid"
}

ct_agent_pattern() {
    if [ -x "$CT_AGENT" ]; then
        printf '%s' "$CT_AGENT"
    else
        printf '%s' "$CT_AGENT_BASENAME"
    fi
}

verify_cold_turkey_installation() {
    [ -d "$CT_APP_BUNDLE" ] || return 1
    [ -f "$CT_LAUNCH_AGENT_PLIST" ] || return 1
    return 0
}

start_cold_turkey() {
    local user_name uid
    verify_cold_turkey_installation || return 1
    user_name="$(console_user)"
    uid="$(console_user_uid)"
    [ -n "$uid" ] || return 1
    launchctl asuser "$uid" sudo -u "$user_name" open -gj -a "$CT_APP_BUNDLE" >/dev/null 2>&1
}

timestamp() {
    date "+%Y-%m-%d %H:%M:%S"
}

log_line() {
    local log_file="$1"
    shift
    printf '[%s] %s\n' "$(timestamp)" "$*" >> "$log_file"
}

mode() {
    if [ -f "$MODE_FILE" ]; then
        cat "$MODE_FILE"
    else
        printf 'locked'
    fi
}

set_mode() {
    local new_mode="$1"
    mkdir -p "$STATE_DIR"
    printf '%s\n' "$new_mode" > "$MODE_FILE"
}

raw_hash() {
    python3 - <<'PY' "$ACTIVE_DB"
import hashlib, sqlite3, sys
db_path = sys.argv[1]
last_error = None
for uri in (f"file:{db_path}?mode=ro", f"file:{db_path}?mode=ro&immutable=1"):
    try:
        conn = sqlite3.connect(uri, uri=True)
        break
    except sqlite3.OperationalError as exc:
        last_error = exc
else:
    raise last_error
try:
    raw = conn.execute("SELECT value FROM settings WHERE key='settings'").fetchone()[0]
finally:
    conn.close()
print(hashlib.sha256(raw.encode()).hexdigest())
PY
}

file_signature() {
    local path="$1"
    if [ ! -e "$path" ]; then
        printf 'missing'
        return 0
    fi
    stat -f '%m:%z' "$path"
}

state_signature() {
    local app_hash
    app_hash="$(raw_hash 2>/dev/null || printf 'unreadable')"
    printf 'app-settings:%s\n' "$app_hash"
}

refresh_state_signature() {
    state_signature > "$HASH_FILE"
}

stop_cold_turkey() {
    local pattern
    pattern="$(ct_agent_pattern)"
    pkill -f "$pattern" 2>/dev/null || true

    local timeout=20
    while pgrep -f "$pattern" >/dev/null 2>&1; do
        pkill -f "$pattern" 2>/dev/null || true
        sleep 1
        timeout=$((timeout - 1))
        if [ "$timeout" -le 0 ]; then
            return 1
        fi
    done
}

sqlite_integrity_ok() {
    local db="$1"
    sqlite3 "$db" 'PRAGMA integrity_check;' | grep -qx 'ok'
}

remove_sqlite_sidecars() {
    local db="$1"
    rm -f "$db-wal" "$db-shm"
}

restore_one_gold_into_active() {
    local gold_db="$1"
    local active_db="$2"
    local tmp_db="$3"
    local active_metadata=""

    [ -f "$gold_db" ] || return 0
    sqlite_integrity_ok "$gold_db" || return 1
    active_metadata="$(file_metadata "$active_db")"
    rm -f "$tmp_db"
    remove_sqlite_sidecars "$active_db"
    cp "$gold_db" "$tmp_db"
    sqlite_integrity_ok "$tmp_db" || return 1
    mv -f "$tmp_db" "$active_db"
    remove_sqlite_sidecars "$active_db"
    apply_file_metadata "$active_db" "$active_metadata"
}

backup_active_to_gold() {
    local active_db="$1"
    local gold_db="$2"
    local tmp_gold="$3"

    [ -f "$active_db" ] || return 0
    sqlite_integrity_ok "$active_db" || return 1
    rm -f "$tmp_gold"
    sqlite_backup "$active_db" "$tmp_gold"
    sqlite_integrity_ok "$tmp_gold" || return 1
    mv -f "$tmp_gold" "$gold_db"
    chown root:wheel "$gold_db" 2>/dev/null || true
    chmod 644 "$gold_db" 2>/dev/null || true
}

ensure_required_gold_dbs() {
    [ -f "$GOLD_DB" ] || return 1

    if [ -f "$ACTIVE_BROWSER_DB" ] || [ -f "$GOLD_BROWSER_DB" ]; then
        [ -f "$GOLD_BROWSER_DB" ] || return 1
    fi

    if [ -f "$ACTIVE_HELPER_DB" ] || [ -f "$GOLD_HELPER_DB" ]; then
        [ -f "$GOLD_HELPER_DB" ] || return 1
    fi
}

verify_gold_baselines_healthy() {
    sqlite_integrity_ok "$GOLD_DB" || return 1

    if [ -f "$GOLD_BROWSER_DB" ]; then
        sqlite_integrity_ok "$GOLD_BROWSER_DB" || return 1
    fi

    if [ -f "$GOLD_HELPER_DB" ]; then
        sqlite_integrity_ok "$GOLD_HELPER_DB" || return 1
    fi
}

restore_policy_gold_into_active_stopped() {
    local tmp_dir="$1"
    [ -f "$GOLD_DB" ] || return 1
    [ -f "$ACTIVE_DB" ] || return 1

    mkdir -p "$tmp_dir"
    restore_one_gold_into_active "$GOLD_DB" "$ACTIVE_DB" "$tmp_dir/data-app.db.tmp" || return 1
}

restore_stats_gold_into_active_stopped() {
    local tmp_dir="$1"

    mkdir -p "$tmp_dir"
    restore_one_gold_into_active "$GOLD_BROWSER_DB" "$ACTIVE_BROWSER_DB" "$tmp_dir/data-browser.db.tmp" || return 1
    restore_one_gold_into_active "$GOLD_HELPER_DB" "$ACTIVE_HELPER_DB" "$tmp_dir/data-helper.db.tmp" || return 1
}

restore_gold_state_into_active() {
    local tmp_dir="$1"

    mkdir -p "$tmp_dir"
    stop_cold_turkey || return 1
    restore_policy_gold_into_active_stopped "$tmp_dir" || return 1
    restore_stats_gold_into_active_stopped "$tmp_dir" || return 1
    refresh_state_signature
    start_cold_turkey >/dev/null 2>&1 || true
}

promote_active_state_to_gold() {
    local tmp_dir="$1"

    mkdir -p "$tmp_dir" "$GOLD_DIR"
    backup_active_to_gold "$ACTIVE_DB" "$GOLD_DB" "$tmp_dir/data-app.db.tmp" || return 1
    backup_active_to_gold "$ACTIVE_BROWSER_DB" "$GOLD_BROWSER_DB" "$tmp_dir/data-browser.db.tmp" || return 1
    backup_active_to_gold "$ACTIVE_HELPER_DB" "$GOLD_HELPER_DB" "$tmp_dir/data-helper.db.tmp" || return 1
    refresh_state_signature
}

promote_policy_active_to_gold() {
    local tmp_dir="$1"

    mkdir -p "$tmp_dir" "$GOLD_DIR"
    backup_active_to_gold "$ACTIVE_DB" "$GOLD_DB" "$tmp_dir/data-app.db.tmp" || return 1
    refresh_state_signature
}

restore_policy_gold_into_active() {
    local tmp_dir="$1"

    mkdir -p "$tmp_dir"
    stop_cold_turkey || return 1
    restore_policy_gold_into_active_stopped "$tmp_dir" || return 1
    refresh_state_signature
    start_cold_turkey >/dev/null 2>&1 || true
}

restore_stats_gold_into_active() {
    local tmp_dir="$1"

    mkdir -p "$tmp_dir"
    stop_cold_turkey || return 1
    restore_stats_gold_into_active_stopped "$tmp_dir" || return 1
    refresh_state_signature
    start_cold_turkey >/dev/null 2>&1 || true
}
