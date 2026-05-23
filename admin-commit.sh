#!/bin/bash

set -euo pipefail

source "/Library/Application Support/FrozenTurkeyLocker/common.sh"

LOG_FILE="$LOG_DIR/admin.log"
TMP_GOLD="$GOLD_DIR/.data-app.db.tmp"

log() {
    log_line "$LOG_FILE" "$@"
}

main() {
    mkdir -p "$STATE_DIR" "$GOLD_DIR" "$LOG_DIR"

    [ "$(mode)" = "unlocked" ] || { log "ERROR: Not in unlocked mode"; exit 1; }
    promote_active_to_gold "$TMP_GOLD" || { log "ERROR: commit failed"; exit 1; }
    set_mode "locked"
    log "Committed changes; new gold baseline accepted and mode locked"
}

main "$@"
