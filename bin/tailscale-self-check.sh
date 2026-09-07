#!/bin/bash
# tailscale-self-check.sh — daily watchdog for the LOCAL Tailscale daemon.
# Deploy on every always-on node. Runs identically on Linux (cron) and macOS
# (launchd); bash 3.2 compatible.
#
# Flags:
#   --dry-run                Print what would alert; do not write state or webhook.
#   --status-from-file PATH  Read tailscale status JSON from PATH instead of CLI (testing only).
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"
set -euo pipefail

# --- config ------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$REPO_DIR/lib/state-machine.sh"
NOTIFY_LIB="$REPO_DIR/lib/notify.sh"

# Per-deploy settings live in config.env (copy config.env.example). Anything
# already exported in the environment wins over the file.
CONFIG_FILE="${TS_WATCHDOG_CONFIG:-$REPO_DIR/config.env}"
if [[ -f "$CONFIG_FILE" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
    set +a
fi

KEY_EXPIRY_WARN_DAYS="${KEY_EXPIRY_WARN_DAYS:-14}"

# TAILSCALE_BIN lets macOS (where the CLI lives inside Tailscale.app) override.
TAILSCALE_BIN="${TAILSCALE_BIN:-tailscale}"

LOG_FILE="${TS_WATCHDOG_LOG_FILE:-$HOME/.local/share/tailscale-fleet-watchdog/watchdog.log}"
export TS_MONITOR_STATE_FILE="${TS_MONITOR_STATE_FILE:-$HOME/.local/state/tailscale-fleet-watchdog/state.json}"
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$TS_MONITOR_STATE_FILE")"

# Detect GNU vs BSD date for cross-platform date math (Linux vs macOS)
if date -d '@0' >/dev/null 2>&1; then
    _DATE_FLAVOR="gnu"
else
    _DATE_FLAVOR="bsd"
fi

iso_to_epoch() {
    # Convert an ISO-8601 UTC timestamp to a Unix epoch. Returns "" on failure.
    local iso="$1"
    if [[ "$_DATE_FLAVOR" == "gnu" ]]; then
        date -d "$iso" +%s 2>/dev/null
    else
        date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null
    fi
}

# --- args --------------------------------------------------------------------
STATUS_FROM_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) export TS_MONITOR_DRY_RUN=1; shift ;;
        --status-from-file) STATUS_FROM_FILE="$2"; export TS_MONITOR_DRY_RUN=1; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

log() {
    echo "[$(date -Iseconds)] [self-check] $*" >> "$LOG_FILE" 2>/dev/null || true
    echo "[$(date -Iseconds)] [self-check] $*" >&2
}

# --- notification wiring (tests/dry-run inject their own discord_send_alert) --
# lib/state-machine.sh calls `discord_send_alert <message>` via dynamic
# dispatch. In dry-run mode nothing is sent, so we only wire the real sender
# when we intend to post.
if [[ "${TS_MONITOR_DRY_RUN:-0}" != "1" ]]; then
    # shellcheck source=/dev/null
    source "$NOTIFY_LIB"
    # shellcheck disable=SC2317
    discord_send_alert() {
        # fire_alert hands us one multi-line string: first line is the headline,
        # the rest is detail. Split on the first newline to fit the embed shape.
        local msg="$1" title body
        title="${msg%%$'\n'*}"
        if [[ "$msg" == *$'\n'* ]]; then
            body="${msg#*$'\n'}"
        else
            body="$title"
        fi
        send_webhook_alert "$title" "$body" 2>>"$LOG_FILE" || log "webhook post failed"
    }
fi

# shellcheck source=/dev/null
source "$LIB"

# --- main --------------------------------------------------------------------
NODE="$(hostname)"

if [[ -n "$STATUS_FROM_FILE" ]]; then
    status_json="$(cat "$STATUS_FROM_FILE")"
elif ! status_json=$("$TAILSCALE_BIN" status --json 2>/dev/null); then
    fire_alert "$NODE:cli-failed" "🛑 [$NODE] tailscale CLI returned non-zero — check daemon"
    exit 0
else
    clear_alert "$NODE:cli-failed"
fi

if ! echo "$status_json" | jq empty 2>/dev/null; then
    fire_alert "$NODE:cli-failed" "🛑 [$NODE] tailscale status returned malformed JSON"
    exit 0
fi

backend_state=$(echo "$status_json" | jq -r '.BackendState // "unknown"')
if [[ "$backend_state" != "Running" ]]; then
    fire_alert "$NODE:backend-not-running" \
"🛑 [$NODE] Tailscale daemon logged out
   BackendState: $backend_state (was Running)
   Detected: $(date -u +'%Y-%m-%d %H:%M UTC')
   Action: SSH onto box → sudo tailscale up → click auth URL"
    exit 0
else
    clear_alert "$NODE:backend-not-running"
fi

# Key expiry — only present in JSON when keyExpiryDisabled=false on the node
key_expiry=$(echo "$status_json" | jq -r '.Self.KeyExpiry // empty')
days_left="N/A"
if [[ -n "$key_expiry" ]]; then
    expiry_epoch=$(iso_to_epoch "$key_expiry")
    if [[ -z "$expiry_epoch" ]]; then
        fire_alert "$NODE:cli-failed" "🛑 [$NODE] could not parse KeyExpiry timestamp: $key_expiry"
        exit 0
    fi
    now_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    if (( days_left < 0 )); then
        # Already expired — distinct key so it fires fresh even if "expiring soon" was already on
        fire_alert "$NODE:key-expired" \
"⛔ [$NODE] Tailscale node key EXPIRED ${days_left#-} days ago
   Expiry: $key_expiry
   Action: sudo tailscale up — daemon is likely already failing"
        clear_alert "$NODE:key-expiring-soon"
    elif (( days_left < KEY_EXPIRY_WARN_DAYS )); then
        fire_alert "$NODE:key-expiring-soon" \
"⏰ [$NODE] Tailscale node key expires in $days_left days
   Expiry: $key_expiry
   Action: sudo tailscale up → reauth in browser
   Or disable expiry permanently in admin console for always-on nodes"
        clear_alert "$NODE:key-expired"
    else
        clear_alert "$NODE:key-expiring-soon"
        clear_alert "$NODE:key-expired"
    fi
else
    clear_alert "$NODE:key-expiring-soon"
    clear_alert "$NODE:key-expired"
fi

log "self-check complete: backend=$backend_state, key_days_left=$days_left"
