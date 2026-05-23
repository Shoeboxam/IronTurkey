#!/bin/bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SUPPORT_DIR="/Library/Application Support/FrozenTurkeyLocker"
LAUNCH_DAEMONS_DIR="/Library/LaunchDaemons"
APP_DST="/Applications/Frozen Turkey Locker.app"
GUARD_PLIST="com.frozenturkey.locker.guard.plist"
RESTORE_PLIST="com.frozenturkey.locker.restore.plist"

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

require_root

bash "$REPO_DIR/build_app.sh"

mkdir -p "$SUPPORT_DIR/gold" "$SUPPORT_DIR/logs" "$SUPPORT_DIR/state"

copy_script "$REPO_DIR/common.sh" "$SUPPORT_DIR/common.sh"
copy_script "$REPO_DIR/guard.sh" "$SUPPORT_DIR/guard.sh"
copy_script "$REPO_DIR/enforce.sh" "$SUPPORT_DIR/enforce.sh"
copy_script "$REPO_DIR/admin-enter-unlocked.sh" "$SUPPORT_DIR/admin-enter-unlocked.sh"
copy_script "$REPO_DIR/admin-commit.sh" "$SUPPORT_DIR/admin-commit.sh"
copy_script "$REPO_DIR/admin-lock.sh" "$SUPPORT_DIR/admin-lock.sh"

cp "$REPO_DIR/policy_compare.py" "$SUPPORT_DIR/policy_compare.py"
chown root:wheel "$SUPPORT_DIR/policy_compare.py"
chmod 755 "$SUPPORT_DIR/policy_compare.py"

cp "$REPO_DIR/com.frozenturkey.locker.guard.plist" "$LAUNCH_DAEMONS_DIR/$GUARD_PLIST"
cp "$REPO_DIR/com.frozenturkey.locker.restore.plist" "$LAUNCH_DAEMONS_DIR/$RESTORE_PLIST"
chown root:wheel "$LAUNCH_DAEMONS_DIR/$GUARD_PLIST" "$LAUNCH_DAEMONS_DIR/$RESTORE_PLIST"
chmod 644 "$LAUNCH_DAEMONS_DIR/$GUARD_PLIST" "$LAUNCH_DAEMONS_DIR/$RESTORE_PLIST"

printf 'locked\n' > "$SUPPORT_DIR/state/mode"
chown -R root:wheel "$SUPPORT_DIR"
chmod 700 "$SUPPORT_DIR" "$SUPPORT_DIR/gold" "$SUPPORT_DIR/logs" "$SUPPORT_DIR/state"

if [ ! -f "$SUPPORT_DIR/gold/data-app.db" ] && [ -f "/Library/Application Support/Cold Turkey/data-app.db" ]; then
    cp "/Library/Application Support/Cold Turkey/data-app.db" "$SUPPORT_DIR/gold/data-app.db"
    chown root:wheel "$SUPPORT_DIR/gold/data-app.db"
    chmod 600 "$SUPPORT_DIR/gold/data-app.db"
fi

rm -rf "$APP_DST"
cp -R "$REPO_DIR/build/Frozen Turkey Locker.app" "$APP_DST"
chown -R root:wheel "$APP_DST"

if [ -n "${SUDO_USER:-}" ]; then
    chown -R "$SUDO_USER":staff "$REPO_DIR/build" 2>/dev/null || true
fi

launchctl bootout system "$LAUNCH_DAEMONS_DIR/$GUARD_PLIST" 2>/dev/null || true
launchctl bootout system "$LAUNCH_DAEMONS_DIR/$RESTORE_PLIST" 2>/dev/null || true
launchctl bootstrap system "$LAUNCH_DAEMONS_DIR/$GUARD_PLIST"
launchctl bootstrap system "$LAUNCH_DAEMONS_DIR/$RESTORE_PLIST"

echo "Installed Frozen Turkey Locker."
echo "App: $APP_DST"
echo "Support dir: $SUPPORT_DIR"
