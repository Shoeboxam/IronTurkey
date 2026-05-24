#!/bin/bash

set -euo pipefail
umask 077

source "/Library/Application Support/IronTurkeyLocker/common.sh"

LOG_FILE="$LOG_DIR/guard.log"
TMP_DIR="$STATE_DIR/guard-tmp"
COMPARE_SCRIPT="$ENFORCER_DIR/policy_compare.py"
STATS_COMPARE_SCRIPT="$ENFORCER_DIR/stats_compare.py"
STARTUP_GRACE_SECONDS=45
AGENT_MISSING_GRACE_SECONDS=120
SETTLE_SECONDS=8
MAX_UNSETTLED_SECONDS=30
COMPARATOR_ERROR_LIMIT=3
AGENT_RESTART_SECONDS=180

json_summary() {
    local path="$1"
    local label="$2"
    python3 - <<'PY' "$path" "$label"
import json
import sys

path, label = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    print(f"{label}=unreadable")
    raise SystemExit(0)

relation = data.get("relation", "error")
reasons = data.get("reasons") or []
shown = reasons[:3]
summary = "; ".join(shown)
remaining = len(reasons) - len(shown)
if remaining > 0:
    summary = f"{summary}; +{remaining} more" if summary else f"+{remaining} more"
if not summary:
    summary = "no details"
print(f"{label}={relation}: {summary}")
PY
}

combined_change_summary() {
    local parts=()

    if [ -f "$COMPARE_OUT" ]; then
        parts+=("$(json_summary "$COMPARE_OUT" "policy")")
    fi
    if [ -f "$STATS_COMPARE_OUT" ]; then
        parts+=("$(json_summary "$STATS_COMPARE_OUT" "stats")")
    fi

    local joined=""
    local part
    for part in "${parts[@]}"; do
        if [ -n "$joined" ]; then
            joined="$joined | "
        fi
        joined="$joined$part"
    done
    printf '%s' "$joined"
}

policy_is_at_least_as_strict() {
    python3 "$COMPARE_SCRIPT" --gold-db "$GOLD_DB" --live-db "$ACTIVE_DB" --json >"$COMPARE_OUT" 2>&1
}

stats_are_monotone() {
    python3 "$STATS_COMPARE_SCRIPT" \
        --policy-db "$ACTIVE_DB" \
        --gold-browser-db "$GOLD_BROWSER_DB" \
        --live-browser-db "$ACTIVE_BROWSER_DB" \
        --gold-helper-db "$GOLD_HELPER_DB" \
        --live-helper-db "$ACTIVE_HELPER_DB" \
        --json >"$STATS_COMPARE_OUT" 2>&1
}

json_relation() {
    local path="$1"
    python3 - <<'PY' "$path"
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

comparison_relation() {
    json_relation "$COMPARE_OUT"
}

stats_relation() {
    json_relation "$STATS_COMPARE_OUT"
}

log() {
    log_line "$LOG_FILE" "$@"
}

lock_request_file_path() {
    lock_request_file
}

lock_request_pending() {
    [ -f "$(lock_request_file_path)" ]
}

clear_lock_request() {
    rm -f "$(lock_request_file_path)"
}

restore_policy_gold() {
    restore_policy_gold_into_active "$TMP_DIR" || {
        log "ERROR: restore_policy_gold failed"
        exit 1
    }
    local summary
    summary="$(combined_change_summary)"
    if [ -n "$summary" ]; then
        log "Unauthorized policy weakening restored: $summary"
    else
        log "Unauthorized policy weakening restored"
    fi
}

restore_stats_gold() {
    restore_stats_gold_into_active "$TMP_DIR" || {
        log "ERROR: restore_stats_gold failed"
        exit 1
    }
    local summary
    summary="$(combined_change_summary)"
    if [ -n "$summary" ]; then
        log "Unauthorized stats weakening restored: $summary"
    else
        log "Unauthorized stats weakening restored"
    fi
}

promote_live_to_gold() {
    promote_active_state_to_gold "$TMP_DIR" || {
        log "ERROR: promote_live_to_gold failed"
        exit 1
    }
    local summary
    summary="$(combined_change_summary)"
    if [ -n "$summary" ]; then
        log "Promoted live state to gold: $summary"
    else
        log "Promoted live state to gold"
    fi
}

main() {
    mkdir -p "$STATE_DIR" "$LOG_DIR" "$TMP_DIR"
    [ -f "$ACTIVE_DB" ] || { log "ERROR: Active database not found at $ACTIVE_DB"; exit 1; }
    [ -f "$COMPARE_SCRIPT" ] || { log "ERROR: Comparator not found at $COMPARE_SCRIPT"; exit 1; }
    [ -f "$STATS_COMPARE_SCRIPT" ] || { log "ERROR: Stats comparator not found at $STATS_COMPARE_SCRIPT"; exit 1; }
    ensure_required_gold_dbs "$TMP_DIR" || { log "ERROR: Unable to initialize protected baselines"; exit 1; }
    verify_gold_baselines_healthy || { log "ERROR: Protected baselines failed integrity checks"; exit 1; }

    local last_running=0
    local grace_until=0
    local missing_since=0
    local pending_signature=""
    local pending_since=0
    local churn_since=0
    local last_error=""
    local comparator_errors=0
    local stats_errors=0
    local restart_attempted=0

    if [ ! -f "$HASH_FILE" ]; then
        state_signature > "$HASH_FILE"
        log "Initialized state signature"
    fi

    log "Guard watcher started"
    if ! verify_cold_turkey_installation; then
        log "ERROR: Cold Turkey install check failed; expected app bundle or launch agent is missing"
        exit 1
    fi

    while true; do
        current_mode="$(mode)"
        request_file="$(lock_request_file_path)"

        if [ -f "$request_file" ]; then
            clear_lock_request
            if [ "$current_mode" = "unlocked" ]; then
                restore_policy_gold_into_active "$TMP_DIR" || {
                    log "ERROR: user-requested relock failed"
                    exit 1
                }
                set_mode "locked"
                log "User-requested relock completed"
                current_mode="locked"
                grace_until=$(( $(date +%s) + STARTUP_GRACE_SECONDS ))
                last_running=0
                pending_signature=""
                pending_since=0
                churn_since=0
                comparator_errors=0
                stats_errors=0
                last_error=""
            fi
        fi

        if [ "$current_mode" = "locked" ]; then
            now="$(date +%s)"

            if ! ct_agent_running; then
                if [ "$last_running" -eq 1 ]; then
                    log "Cold Turkey agent disappeared; waiting for restart before enforcing"
                fi
                last_running=0
                if [ "$missing_since" -eq 0 ]; then
                    missing_since="$now"
                    restart_attempted=0
                fi
                grace_until=$((now + AGENT_MISSING_GRACE_SECONDS))
                pending_signature=""
                pending_since=0
                churn_since=0

                if [ $((now - missing_since)) -ge "$AGENT_RESTART_SECONDS" ] && [ "$restart_attempted" -eq 0 ]; then
                    if start_cold_turkey; then
                        log "Cold Turkey agent was absent too long; attempted relaunch"
                        restart_attempted=1
                        grace_until=$((now + STARTUP_GRACE_SECONDS))
                    else
                        log "ERROR: Cold Turkey agent was absent too long and relaunch failed"
                        restart_attempted=1
                    fi
                fi

                sleep 2
                continue
            fi

            if [ "$last_running" -eq 0 ]; then
                last_running=1
                missing_since=0
                restart_attempted=0
                if [ "$grace_until" -lt $((now + STARTUP_GRACE_SECONDS)) ]; then
                    grace_until=$((now + STARTUP_GRACE_SECONDS))
                fi
                pending_signature=""
                pending_since=0
                churn_since=0
                log "Cold Turkey agent detected; waiting for startup to stabilize"
            fi

            if [ "$now" -lt "$grace_until" ]; then
                sleep 2
                continue
            fi

            if ! ensure_required_gold_dbs "$TMP_DIR"; then
                log "ERROR: Protected baselines are missing; refusing to continue"
                exit 1
            fi

            if ! verify_gold_baselines_healthy; then
                log "ERROR: Protected baselines failed integrity checks; refusing to continue"
                exit 1
            fi

            current_signature="$(state_signature 2>/dev/null || true)"
            if [ -z "$current_signature" ]; then
                if [ "$last_error" != "signature" ]; then
                    log "Unable to read live state signature; skipping this cycle"
                    last_error="signature"
                fi
                sleep 2
                continue
            fi

            if [ "$current_signature" != "$pending_signature" ]; then
                if [ "$churn_since" -eq 0 ]; then
                    churn_since="$now"
                fi
                pending_signature="$current_signature"
                pending_since="$now"
                if [ $((now - churn_since)) -lt "$MAX_UNSETTLED_SECONDS" ]; then
                    sleep 2
                    continue
                fi
            fi

            if [ $((now - pending_since)) -lt "$SETTLE_SECONDS" ] && [ $((now - churn_since)) -lt "$MAX_UNSETTLED_SECONDS" ]; then
                sleep 2
                continue
            fi

            policy_is_at_least_as_strict || true
            relation="$(comparison_relation)"

            if [ "$relation" = "weaker" ]; then
                comparator_errors=0
                compare_output="$(cat "$COMPARE_OUT" 2>/dev/null || true)"
                if [ -n "$compare_output" ]; then
                    log "Comparator rejected live policy: $compare_output"
                fi
                restore_policy_gold
                grace_until=$((now + STARTUP_GRACE_SECONDS))
                last_running=0
                pending_signature=""
                pending_since=0
                churn_since=0
                last_error=""
                sleep 2
                continue
            fi

            if [ "$relation" != "equal" ] && [ "$relation" != "stronger" ]; then
                comparator_errors=$((comparator_errors + 1))
                compare_output="$(cat "$COMPARE_OUT" 2>/dev/null || true)"
                if [ "$compare_output" != "$last_error" ]; then
                    log "Policy comparator returned an unusable result; skipping this cycle"
                    if [ -n "$compare_output" ]; then
                        log "Policy comparator output: $compare_output"
                    fi
                    last_error="$compare_output"
                fi
                if [ "$comparator_errors" -ge "$COMPARATOR_ERROR_LIMIT" ]; then
                    log "Policy comparator exceeded retry budget; restoring gold fail-closed"
                    restore_policy_gold
                    comparator_errors=0
                    stats_errors=0
                    grace_until=$((now + STARTUP_GRACE_SECONDS))
                    last_running=0
                    pending_signature=""
                    pending_since=0
                    churn_since=0
                    last_error=""
                    sleep 2
                    continue
                fi
                sleep 2
                continue
            fi
            comparator_errors=0

            stats_are_monotone || true
            stats_rel="$(stats_relation)"

            if [ "$stats_rel" = "weaker" ]; then
                stats_errors=0
                stats_output="$(cat "$STATS_COMPARE_OUT" 2>/dev/null || true)"
                if [ -n "$stats_output" ]; then
                    log "Stats comparator rejected live stats: $stats_output"
                fi
                restore_stats_gold
                grace_until=$((now + STARTUP_GRACE_SECONDS))
                last_running=0
                pending_signature=""
                pending_since=0
                churn_since=0
                last_error=""
                sleep 2
                continue
            fi

            if [ "$stats_rel" != "equal" ] && [ "$stats_rel" != "stronger" ]; then
                stats_errors=$((stats_errors + 1))
                stats_output="$(cat "$STATS_COMPARE_OUT" 2>/dev/null || true)"
                if [ "$stats_output" != "$last_error" ]; then
                    log "Stats comparator returned an unusable result; skipping this cycle"
                    if [ -n "$stats_output" ]; then
                        log "Stats comparator output: $stats_output"
                    fi
                    last_error="$stats_output"
                fi
                if [ "$stats_errors" -ge "$COMPARATOR_ERROR_LIMIT" ]; then
                    log "Stats comparator exceeded retry budget; restoring gold fail-closed"
                    restore_stats_gold
                    comparator_errors=0
                    stats_errors=0
                    grace_until=$((now + STARTUP_GRACE_SECONDS))
                    last_running=0
                    pending_signature=""
                    pending_since=0
                    churn_since=0
                    last_error=""
                    sleep 2
                    continue
                fi
                sleep 2
                continue
            fi
            stats_errors=0

            if [ "$relation" = "stronger" ] || [ "$stats_rel" = "stronger" ]; then
                promote_live_to_gold
                last_error=""
                pending_signature=""
                pending_since=0
                churn_since=0
            else
                state_signature > "$HASH_FILE"
                last_error=""
                pending_signature=""
                pending_since=0
                churn_since=0
            fi
        else
            last_running=0
            pending_signature=""
            pending_since=0
            churn_since=0
        fi

        sleep 2
    done
}

main "$@"
