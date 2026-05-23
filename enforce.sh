#!/bin/bash

set -euo pipefail

ACTIVE_DIR="/Library/Application Support/Cold Turkey"
ACTIVE_DB="$ACTIVE_DIR/data-app.db"
ACTIVE_WAL="$ACTIVE_DIR/data-app.db-wal"
ACTIVE_SHM="$ACTIVE_DIR/data-app.db-shm"

CT_AGENT="/Applications/Cold Turkey Blocker.app/Contents/MacOS/Cold Turkey Blocker -agent"

ENFORCER_DIR="/Library/Application Support/FrozenTurkeyLocker"
LOG_DIR="$ENFORCER_DIR/logs"
LOG_FILE="$LOG_DIR/enforce.log"
LOCK_NOW="$ENFORCER_DIR/admin-lock.sh"

main() {
    mkdir -p "$LOG_DIR"
    printf '[%s] Starting scheduled lock\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    exec "$LOCK_NOW" --scheduled
}

main "$@"
