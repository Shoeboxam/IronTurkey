#!/bin/bash

set -euo pipefail

source "/Library/Application Support/FrozenTurkeyLocker/common.sh"

LOG_FILE="$LOG_DIR/admin.log"

log() {
    log_line "$LOG_FILE" "$@"
}

mkdir -p "$STATE_DIR" "$LOG_DIR"
set_mode "unlocked"
log "Entered unlocked mode"
