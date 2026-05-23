#!/bin/bash

set -euo pipefail

source "/Library/Application Support/FrozenTurkeyLocker/common.sh"

LOG_FILE="$LOG_DIR/admin.log"
TMP_DB="$ACTIVE_DIR/.data-app.db.ctlock.tmp"

log() {
    log_line "$LOG_FILE" "$@"
}

main() {
    mkdir -p "$STATE_DIR" "$LOG_DIR"

    current_mode="$(mode)"
    restore_gold_into_active "$TMP_DB" || { log "ERROR: lock restore failed"; exit 1; }
    set_mode "locked"
    log "Lock completed from mode $current_mode"
}

main "$@"
