#!/bin/bash

set -euo pipefail
umask 077

source "/Library/Application Support/IronTurkeyLocker/common.sh"

LOG_FILE="$LOG_DIR/admin.log"
TMP_DIR="$STATE_DIR/admin-lock-tmp"

log() {
    log_line "$LOG_FILE" "$@"
}

main() {
    mkdir -p "$STATE_DIR" "$LOG_DIR" "$TMP_DIR"

    current_mode="$(mode)"
    restore_policy_gold_into_active "$TMP_DIR" || { log "ERROR: lock restore failed"; exit 1; }
    set_mode "locked"
    log "Lock completed from mode $current_mode"
}

main "$@"
