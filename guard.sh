#!/bin/bash

set -euo pipefail

source "/Library/Application Support/FrozenTurkeyLocker/common.sh"

LOG_FILE="$LOG_DIR/guard.log"
TMP_DB="$ACTIVE_DIR/.data-app.db.ctguard.tmp"
TMP_GOLD="$GOLD_DIR/.data-app.db.tmp"
COMPARE_SCRIPT="$ENFORCER_DIR/policy_compare.py"
STARTUP_GRACE_SECONDS=45
AGENT_MISSING_GRACE_SECONDS=120
SETTLE_SECONDS=8

policy_is_at_least_as_strict() {
    python3 "$COMPARE_SCRIPT" --gold-db "$GOLD_DB" --live-db "$ACTIVE_DB" --json >"$COMPARE_OUT" 2>&1
}

comparison_relation() {
    python3 - <<'PY' "$COMPARE_OUT"
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
    print(data.get("relation", "error"))
except Exception:
    print("error")
PY
}

log() {
    log_line "$LOG_FILE" "$@"
}

restore_gold() {
    restore_gold_into_active "$TMP_DB" || {
        log "ERROR: restore_gold failed"
        exit 1
    }
    log "Unauthorized change detected; policy restored"
}

promote_live_to_gold() {
    promote_active_to_gold "$TMP_GOLD" || {
        log "ERROR: promote_live_to_gold failed"
        exit 1
    }
    compare_output="$(cat "$COMPARE_OUT" 2>/dev/null || true)"
    if [ -n "$compare_output" ]; then
        log "Live policy promoted to gold: $compare_output"
    else
        log "Live policy promoted to gold"
    fi
}

main() {
    mkdir -p "$STATE_DIR" "$LOG_DIR"
    [ -f "$ACTIVE_DB" ] || { log "ERROR: Active database not found at $ACTIVE_DB"; exit 1; }
    [ -f "$COMPARE_SCRIPT" ] || { log "ERROR: Comparator not found at $COMPARE_SCRIPT"; exit 1; }

    local last_running=0
    local grace_until=0
    local pending_hash=""
    local pending_since=0
    local last_error=""

    if [ ! -f "$HASH_FILE" ]; then
        raw_hash > "$HASH_FILE"
        log "Initialized hash state"
    fi

    log "Guard watcher started"

    while true; do
        current_mode="$(mode)"

        if [ "$current_mode" = "locked" ]; then
            now="$(date +%s)"

            if ! ct_agent_running; then
                if [ "$last_running" -eq 1 ]; then
                    log "Cold Turkey agent disappeared; waiting for restart before enforcing"
                fi
                last_running=0
                grace_until=$((now + AGENT_MISSING_GRACE_SECONDS))
                pending_hash=""
                pending_since=0
                sleep 2
                continue
            fi

            if [ "$last_running" -eq 0 ]; then
                last_running=1
                if [ "$grace_until" -lt $((now + STARTUP_GRACE_SECONDS)) ]; then
                    grace_until=$((now + STARTUP_GRACE_SECONDS))
                fi
                pending_hash=""
                pending_since=0
                log "Cold Turkey agent detected; waiting for startup to stabilize"
            fi

            if [ "$now" -lt "$grace_until" ]; then
                sleep 2
                continue
            fi

            current_hash="$(raw_hash 2>/dev/null || true)"
            if [ -z "$current_hash" ]; then
                if [ "$last_error" != "hash" ]; then
                    log "Unable to read live policy hash; skipping this cycle"
                    last_error="hash"
                fi
                sleep 2
                continue
            fi

            if [ "$current_hash" != "$pending_hash" ]; then
                pending_hash="$current_hash"
                pending_since="$now"
                sleep 2
                continue
            fi

            if [ $((now - pending_since)) -lt "$SETTLE_SECONDS" ]; then
                sleep 2
                continue
            fi

            policy_is_at_least_as_strict || true
            relation="$(comparison_relation)"

            if [ "$relation" = "stronger" ]; then
                promote_live_to_gold
                last_error=""
                pending_hash=""
                pending_since=0
            else
                if [ "$relation" = "equal" ]; then
                    raw_hash > "$HASH_FILE"
                    last_error=""
                else
                    if [ "$relation" = "weaker" ]; then
                        compare_output="$(cat "$COMPARE_OUT" 2>/dev/null || true)"
                        if [ -n "$compare_output" ]; then
                            log "Comparator rejected live policy: $compare_output"
                        fi
                        restore_gold
                        grace_until=$((now + STARTUP_GRACE_SECONDS))
                        last_running=0
                        pending_hash=""
                        pending_since=0
                        last_error=""
                    else
                        compare_output="$(cat "$COMPARE_OUT" 2>/dev/null || true)"
                        if [ "$compare_output" != "$last_error" ]; then
                            log "Comparator returned an unusable result; skipping this cycle"
                            if [ -n "$compare_output" ]; then
                                log "Comparator output: $compare_output"
                            fi
                            last_error="$compare_output"
                        fi
                    fi
                fi
            fi
        else
            last_running=0
            pending_hash=""
            pending_since=0
        fi

        sleep 2
    done
}

main "$@"
