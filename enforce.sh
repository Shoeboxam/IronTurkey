#!/bin/bash

set -euo pipefail
umask 077

ENFORCER_DIR="/Library/Application Support/IronTurkeyLocker"
LOG_DIR="$ENFORCER_DIR/logs"
LOG_FILE="$LOG_DIR/enforce.log"
LOCK_NOW="$ENFORCER_DIR/admin-lock.sh"

main() {
    mkdir -p "$LOG_DIR"
    printf '[%s] Starting scheduled lock\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$LOG_FILE"
    exec "$LOCK_NOW" --scheduled
}

main "$@"
