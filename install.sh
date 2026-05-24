#!/bin/bash

set -euo pipefail
umask 077

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SUPPORT_DIR="/Library/Application Support/IronTurkeyLocker"
LAUNCH_DAEMONS_DIR="/Library/LaunchDaemons"
APP_DST="/Applications/Iron Turkey Locker.app"
GUARD_PLIST="com.ironturkey.locker.guard.plist"
RESTORE_PLIST="com.ironturkey.locker.restore.plist"
COLD_TURKEY_DIR="/Library/Application Support/Cold Turkey"

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        echo "Run as root: sudo ./install.sh" >&2
        exit 1
    fi
}

copy_script() {
    local src="$1"
    local dst="$2"
    cp "$src" "$dst"
    chown root:wheel "$dst"
    chmod 700 "$dst"
}

snapshot_sqlite_db() {
    local src="$1"
    local dst="$2"

    python3 - <<'PY' "$src" "$dst"
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

ensure_gold_db() {
    local name="$1"
    local required="${2:-required}"
    local src="/Library/Application Support/Cold Turkey/$name"
    local dst="$SUPPORT_DIR/gold/$name"
    local tmp="$SUPPORT_DIR/gold/$name.install.tmp"

    if [ -f "$dst" ]; then
        return 0
    fi

    if [ ! -f "$src" ]; then
        if [ "$required" = "required" ]; then
            echo "ERROR: Missing live Cold Turkey database: $src" >&2
            return 1
        fi
        return 0
    fi

    rm -f "$tmp"
    snapshot_sqlite_db "$src" "$tmp"
    mv -f "$tmp" "$dst"
    chown root:wheel "$dst"
    chmod 600 "$dst"
}

verify_gold_db() {
    local name="$1"
    local required="${2:-required}"
    local dst="$SUPPORT_DIR/gold/$name"
    local src="/Library/Application Support/Cold Turkey/$name"
    if [ "$required" != "required" ] && [ ! -f "$src" ] && [ ! -f "$dst" ]; then
        return 0
    fi
    if [ ! -f "$dst" ]; then
        echo "ERROR: Missing protected baseline after install: $dst" >&2
        return 1
    fi
}

verify_gold_db_integrity() {
    local name="$1"
    local required="${2:-required}"
    local dst="$SUPPORT_DIR/gold/$name"
    local src="/Library/Application Support/Cold Turkey/$name"

    if [ "$required" != "required" ] && [ ! -f "$src" ] && [ ! -f "$dst" ]; then
        return 0
    fi

    sqlite3 "$dst" 'PRAGMA integrity_check;' | grep -qx 'ok'
}

normalize_cold_turkey_dir() {
    if [ -d "$COLD_TURKEY_DIR" ]; then
        chmod 1777 "$COLD_TURKEY_DIR"
    fi
}

require_root

bash "$REPO_DIR/build_app.sh"
normalize_cold_turkey_dir

mkdir -p "$SUPPORT_DIR/gold" "$SUPPORT_DIR/logs" "$SUPPORT_DIR/state"

copy_script "$REPO_DIR/common.sh" "$SUPPORT_DIR/common.sh"
copy_script "$REPO_DIR/guard.sh" "$SUPPORT_DIR/guard.sh"
copy_script "$REPO_DIR/enforce.sh" "$SUPPORT_DIR/enforce.sh"
copy_script "$REPO_DIR/admin-enter-unlocked.sh" "$SUPPORT_DIR/admin-enter-unlocked.sh"
copy_script "$REPO_DIR/admin-commit.sh" "$SUPPORT_DIR/admin-commit.sh"
copy_script "$REPO_DIR/admin-lock.sh" "$SUPPORT_DIR/admin-lock.sh"
cp "$REPO_DIR/request-lock.sh" "$SUPPORT_DIR/request-lock.sh"
chown root:wheel "$SUPPORT_DIR/request-lock.sh"
chmod 755 "$SUPPORT_DIR/request-lock.sh"

cp "$REPO_DIR/policy_compare.py" "$SUPPORT_DIR/policy_compare.py"
cp "$REPO_DIR/stats_compare.py" "$SUPPORT_DIR/stats_compare.py"
chown root:wheel "$SUPPORT_DIR/policy_compare.py" "$SUPPORT_DIR/stats_compare.py"
chmod 755 "$SUPPORT_DIR/policy_compare.py" "$SUPPORT_DIR/stats_compare.py"

cp "$REPO_DIR/com.ironturkey.locker.guard.plist" "$LAUNCH_DAEMONS_DIR/$GUARD_PLIST"
cp "$REPO_DIR/com.ironturkey.locker.restore.plist" "$LAUNCH_DAEMONS_DIR/$RESTORE_PLIST"
chown root:wheel "$LAUNCH_DAEMONS_DIR/$GUARD_PLIST" "$LAUNCH_DAEMONS_DIR/$RESTORE_PLIST"
chmod 644 "$LAUNCH_DAEMONS_DIR/$GUARD_PLIST" "$LAUNCH_DAEMONS_DIR/$RESTORE_PLIST"

printf 'locked\n' > "$SUPPORT_DIR/state/mode"
chown -R root:wheel "$SUPPORT_DIR"
chmod 755 "$SUPPORT_DIR" "$SUPPORT_DIR/gold" "$SUPPORT_DIR/state"
chmod 700 "$SUPPORT_DIR/logs"
chmod 644 "$SUPPORT_DIR/state/mode"

ensure_gold_db "data-app.db" required
ensure_gold_db "data-browser.db" optional
ensure_gold_db "data-helper.db" optional
verify_gold_db "data-app.db" required
verify_gold_db "data-browser.db" optional
verify_gold_db "data-helper.db" optional
verify_gold_db_integrity "data-app.db" required
verify_gold_db_integrity "data-browser.db" optional
verify_gold_db_integrity "data-helper.db" optional

rm -rf "$APP_DST"
cp -R "$REPO_DIR/build/Iron Turkey Locker.app" "$APP_DST"
chown -R root:wheel "$APP_DST"

if [ -n "${SUDO_USER:-}" ]; then
    chown -R "$SUDO_USER":staff "$REPO_DIR/build" 2>/dev/null || true
fi

chmod 644 "$SUPPORT_DIR"/gold/*.db 2>/dev/null || true

launchctl bootout system "$LAUNCH_DAEMONS_DIR/$GUARD_PLIST" 2>/dev/null || true
launchctl bootout system "$LAUNCH_DAEMONS_DIR/$RESTORE_PLIST" 2>/dev/null || true
launchctl bootstrap system "$LAUNCH_DAEMONS_DIR/$GUARD_PLIST"
launchctl bootstrap system "$LAUNCH_DAEMONS_DIR/$RESTORE_PLIST"

echo "Installed Iron Turkey Locker."
echo "App: $APP_DST"
echo "Support dir: $SUPPORT_DIR"
