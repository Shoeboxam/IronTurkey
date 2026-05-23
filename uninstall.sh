#!/bin/bash

set -euo pipefail

SUPPORT_DIR="/Library/Application Support/FrozenTurkeyLocker"
LAUNCH_DAEMONS_DIR="/Library/LaunchDaemons"
APP_DST="/Applications/Frozen Turkey Locker.app"
GUARD_PLIST="com.frozenturkey.locker.guard.plist"
RESTORE_PLIST="com.frozenturkey.locker.restore.plist"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Run as root: sudo ./uninstall.sh" >&2
    exit 1
fi

launchctl bootout system "$LAUNCH_DAEMONS_DIR/$GUARD_PLIST" 2>/dev/null || true
launchctl bootout system "$LAUNCH_DAEMONS_DIR/$RESTORE_PLIST" 2>/dev/null || true

rm -f "$LAUNCH_DAEMONS_DIR/$GUARD_PLIST" "$LAUNCH_DAEMONS_DIR/$RESTORE_PLIST"
rm -rf "$SUPPORT_DIR" "$APP_DST"

echo "Uninstalled Frozen Turkey Locker."
