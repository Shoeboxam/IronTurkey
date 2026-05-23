#!/bin/bash

set -euo pipefail

ACTIVE_DIR="/Library/Application Support/Cold Turkey"
ACTIVE_DB="$ACTIVE_DIR/data-app.db"
ACTIVE_WAL="$ACTIVE_DIR/data-app.db-wal"
ACTIVE_SHM="$ACTIVE_DIR/data-app.db-shm"

CT_AGENT="/Applications/Cold Turkey Blocker.app/Contents/MacOS/Cold Turkey Blocker -agent"

ENFORCER_DIR="/Library/Application Support/FrozenTurkeyLocker"
STATE_DIR="$ENFORCER_DIR/state"
MODE_FILE="$STATE_DIR/mode"
HASH_FILE="$STATE_DIR/last_hash"
COMPARE_OUT="$STATE_DIR/compare.out"
LOG_DIR="$ENFORCER_DIR/logs"
GOLD_DIR="$ENFORCER_DIR/gold"
GOLD_DB="$GOLD_DIR/data-app.db"

ct_agent_running() {
    pgrep -f "$CT_AGENT" >/dev/null 2>&1
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
conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
try:
    raw = conn.execute("SELECT value FROM settings WHERE key='settings'").fetchone()[0]
finally:
    conn.close()
print(hashlib.sha256(raw.encode()).hexdigest())
PY
}

stop_cold_turkey() {
    pkill -f "$CT_AGENT" 2>/dev/null || true

    local timeout=20
    while pgrep -f "$CT_AGENT" >/dev/null 2>&1; do
        pkill -f "$CT_AGENT" 2>/dev/null || true
        sleep 1
        timeout=$((timeout - 1))
        if [ "$timeout" -le 0 ]; then
            return 1
        fi
    done
}

restore_gold_into_active() {
    local tmp_db="$1"

    [ -f "$GOLD_DB" ] || return 1
    [ -f "$ACTIVE_DB" ] || return 1

    sqlite3 "$GOLD_DB" 'PRAGMA integrity_check;' | grep -qx 'ok' || return 1
    stop_cold_turkey || return 1
    rm -f "$ACTIVE_WAL" "$ACTIVE_SHM" "$tmp_db"
    cp "$GOLD_DB" "$tmp_db"
    sqlite3 "$tmp_db" 'PRAGMA integrity_check;' | grep -qx 'ok' || return 1
    mv -f "$tmp_db" "$ACTIVE_DB"
    rm -f "$ACTIVE_WAL" "$ACTIVE_SHM"
    chown root:admin "$ACTIVE_DB" 2>/dev/null || true
    chmod 666 "$ACTIVE_DB"
    printf '%s\n' "$(raw_hash)" > "$HASH_FILE"
}

promote_active_to_gold() {
    local tmp_gold="$1"

    sqlite3 "$ACTIVE_DB" 'PRAGMA integrity_check;' | grep -qx 'ok' || return 1
    rm -f "$tmp_gold"
    python3 - <<'PY' "$ACTIVE_DB" "$tmp_gold"
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
    sqlite3 "$tmp_gold" 'PRAGMA integrity_check;' | grep -qx 'ok' || return 1
    mv -f "$tmp_gold" "$GOLD_DB"
    printf '%s\n' "$(raw_hash)" > "$HASH_FILE"
}
