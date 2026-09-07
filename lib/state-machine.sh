#!/bin/bash
# state-machine.sh — shared alert state machine for tailscale-self-check.sh
# and tailscale-fleet-audit.sh. Alerts fire on TRANSITIONS only: a condition
# that is already open is deduplicated until it clears.
#
# Sourced, not executed. Functions provided:
#   fire_alert <key> <message>   — send Discord webhook (deduped) + write state
#   clear_alert <key>            — mark alert resolved silently
#
# Required env vars (caller must set):
#   TS_MONITOR_STATE_FILE        — absolute path to JSON state file
#
# Optional env vars:
#   TS_MONITOR_DRY_RUN           — if "1", print what would happen, skip side effects
#
# Caller must define `discord_send_alert <message>` (mocked in tests; the real
# implementation in bin/ wraps lib/notify.sh).

# --- internals ---------------------------------------------------------------

_now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# Ensure the state file is valid JSON. If not, reset it AND fire meta:state-reset
# (once, only on the very first reset call this run).
_ensure_state_file_valid() {
    local f="$TS_MONITOR_STATE_FILE"
    mkdir -p "$(dirname "$f")"
    if [[ ! -f "$f" ]]; then
        echo '{"schema_version": 1, "alerts": {}}' > "$f"
        return
    fi
    if ! jq empty "$f" 2>/dev/null; then
        echo '{"schema_version": 1, "alerts": {}}' > "$f"
        # Fire reset alert exactly once, but use direct write to avoid recursion
        local now; now=$(_now_iso)
        local tmp; tmp=$(mktemp "$f.XXXXXX")
        if ! jq --arg now "$now" \
            '.alerts["meta:state-reset"] = {first_fired_at:$now, last_fired_at:$now, cleared:false, cleared_at:null, context:{}}' \
            "$f" > "$tmp"; then
            rm -f "$tmp"
            echo "_ensure_state_file_valid: jq failed writing meta:state-reset" >&2
            return 1
        fi
        mv "$tmp" "$f"
        if [[ "${TS_MONITOR_DRY_RUN:-0}" != "1" ]]; then
            discord_send_alert "🛑 [$(hostname)] tailscale-monitor meta:state-reset — state file was corrupt and has been reset"
        else
            echo "[DRY-RUN] would fire: meta:state-reset"
        fi
    fi
}

# --- public functions --------------------------------------------------------

fire_alert() {
    local key="$1" message="$2"
    _ensure_state_file_valid
    local f="$TS_MONITOR_STATE_FILE"
    exec 9>"$f.lock"
    # flock is Linux-only; macOS bash has no equivalent. Daily cron means
    # concurrent invocation is essentially impossible — best-effort lock only.
    command -v flock >/dev/null 2>&1 && flock 9
    local now; now=$(_now_iso)
    local cleared
    if ! cleared=$(jq -r --arg k "$key" 'if .alerts[$k] == null then "absent" else (.alerts[$k].cleared|tostring) end' "$f"); then
        echo "fire_alert: jq read failed on state file" >&2
        return 1
    fi
    if [[ "$cleared" == "false" ]]; then
        # Already fired and not yet cleared — dedup, but touch last_fired_at
        local tmp; tmp=$(mktemp "$f.XXXXXX")
        if ! jq --arg k "$key" --arg now "$now" \
            '.alerts[$k].last_fired_at = $now' \
            "$f" > "$tmp"; then
            rm -f "$tmp"
            return 0  # Dedup path — best-effort touch, don't propagate failure
        fi
        mv "$tmp" "$f"
        return 0
    fi
    # Either absent or previously cleared — fire and record
    local tmp; tmp=$(mktemp "$f.XXXXXX")
    if ! jq --arg k "$key" --arg now "$now" \
        '.alerts[$k] = {first_fired_at:$now, last_fired_at:$now, cleared:false, cleared_at:null, context:{}}' \
        "$f" > "$tmp"; then
        rm -f "$tmp"
        echo "fire_alert: jq failed writing state for $key" >&2
        return 1
    fi
    mv "$tmp" "$f"
    if [[ "${TS_MONITOR_DRY_RUN:-0}" != "1" ]]; then
        discord_send_alert "$message"
    else
        echo "[DRY-RUN] would fire: $key — $message"
    fi
}

clear_alert() {
    local key="$1"
    _ensure_state_file_valid
    local f="$TS_MONITOR_STATE_FILE"
    exec 9>"$f.lock"
    # flock is Linux-only; macOS bash has no equivalent. Daily cron means
    # concurrent invocation is essentially impossible — best-effort lock only.
    command -v flock >/dev/null 2>&1 && flock 9
    local cleared
    if ! cleared=$(jq -r --arg k "$key" 'if .alerts[$k] == null then "absent" else (.alerts[$k].cleared|tostring) end' "$f"); then
        echo "clear_alert: jq read failed on state file" >&2
        return 1
    fi
    if [[ "$cleared" != "false" ]]; then
        # Either no entry, or already cleared — no-op
        return 0
    fi
    local now; now=$(_now_iso)
    local tmp; tmp=$(mktemp "$f.XXXXXX")
    if ! jq --arg k "$key" --arg now "$now" \
        '.alerts[$k].cleared = true | .alerts[$k].cleared_at = $now' \
        "$f" > "$tmp"; then
        rm -f "$tmp"
        echo "clear_alert: jq failed writing state for $key" >&2
        return 1
    fi
    mv "$tmp" "$f"
}
