#!/bin/bash

set -euo pipefail
umask 077

source "/Library/Application Support/IronTurkeyLocker/common.sh"

LOG_FILE="$LOG_DIR/admin.log"
TMP_DIR="$GOLD_DIR/.commit-tmp"

log() {
    log_line "$LOG_FILE" "$@"
}

main() {
    mkdir -p "$STATE_DIR" "$GOLD_DIR" "$LOG_DIR" "$TMP_DIR"

    [ "$(mode)" = "unlocked" ] || { log "ERROR: Not in unlocked mode"; exit 1; }
    promote_policy_active_to_gold "$TMP_DIR" || { log "ERROR: commit failed"; exit 1; }
    set_mode "locked"
    log "Committed policy changes; new gold baseline accepted and mode locked"
}

main "$@"
