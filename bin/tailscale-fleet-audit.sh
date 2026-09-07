#!/bin/bash
# tailscale-fleet-audit.sh — weekly fleet-wide check via the Tailscale REST API.
# Run on at least TWO always-on nodes so it survives the node it monitors.
# Detects offline always-on nodes, key-expiry config drift, and imminent
# expiry across the always-on tier. Laptops and phones are deliberately
# excluded via the ALWAYS_ON_NODES config list (not a code branch).
#
# Flags:
#   --dry-run                  Print what would alert; do not write state or webhook.
#   --devices-from-file PATH   Read /devices response JSON from PATH instead of API (testing).

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
OFFLINE_WARN_HOURS_FIRST="${OFFLINE_WARN_HOURS_FIRST:-6}"
OFFLINE_WARN_HOURS_SECOND="${OFFLINE_WARN_HOURS_SECOND:-24}"

# Space-separated MagicDNS short names of the nodes that should ALWAYS be up.
# Laptops and phones are excluded here, by configuration, not by code.
read -r -a ALWAYS_ON_NODES <<< "${ALWAYS_ON_NODES:-}"
if [[ ${#ALWAYS_ON_NODES[@]} -eq 0 ]]; then
    echo "ALWAYS_ON_NODES is empty — set it in $CONFIG_FILE" >&2
    exit 2
fi

CREDS_FILE="${TS_OAUTH_CREDS_FILE:-$HOME/.config/tailscale-fleet-watchdog/credentials.env}"

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
DEVICES_FROM_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) export TS_MONITOR_DRY_RUN=1; shift ;;
        --devices-from-file) DEVICES_FROM_FILE="$2"; export TS_MONITOR_DRY_RUN=1; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

log() {
    echo "[$(date -Iseconds)] [fleet-audit] $*" >> "$LOG_FILE" 2>/dev/null || true
    echo "[$(date -Iseconds)] [fleet-audit] $*" >&2
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

# --- API: OAuth + /devices --------------------------------------------------
# Writes the /devices JSON response to $1 (a path). Returns 0 on success,
# 1 on failure (after firing audit:api-failed). Output to a file (rather
# than stdout) so fire_alert's stdout messages aren't swallowed by command
# substitution when the caller invokes this function.
get_devices_via_api() {
    local out_path="$1"
    if [[ ! -f "$CREDS_FILE" ]]; then
        fire_alert "audit:api-failed" "🛑 fleet-audit: $CREDS_FILE missing — see credentials.env.example"
        return 1
    fi
    # shellcheck source=/dev/null
    source "$CREDS_FILE"
    if [[ -z "${TS_OAUTH_CLIENT_ID:-}" || -z "${TS_OAUTH_CLIENT_SECRET:-}" ]]; then
        fire_alert "audit:api-failed" "🛑 fleet-audit: TS_OAUTH_CLIENT_ID/SECRET missing in $CREDS_FILE"
        return 1
    fi
    if [[ -z "${TS_TAILNET:-}" ]]; then
        fire_alert "audit:api-failed" "🛑 fleet-audit: TS_TAILNET missing in $CREDS_FILE"
        return 1
    fi

    local token_resp http_code
    # -s (not -sf) so we get the body on 4xx/5xx; we check %{http_code} ourselves.
    # -w '\n%{http_code}' appends status as final line; we split via tail/sed.
    # --max-time 30 prevents cron job hanging on unresponsive Tailscale endpoint.
    token_resp=$(curl -s -u "$TS_OAUTH_CLIENT_ID:$TS_OAUTH_CLIENT_SECRET" \
        --max-time 30 \
        -w '\n%{http_code}' \
        -d 'grant_type=client_credentials' \
        https://api.tailscale.com/api/v2/oauth/token 2>>"$LOG_FILE") || {
        fire_alert "audit:api-failed" "🛑 fleet-audit: OAuth curl invocation failed (curl exit $?)"
        return 1
    }
    http_code=$(echo "$token_resp" | tail -n 1)
    token_resp=$(echo "$token_resp" | sed '$d')
    if [[ "$http_code" != "200" ]]; then
        fire_alert "audit:api-failed" "🛑 fleet-audit: OAuth token request returned HTTP $http_code"
        return 1
    fi
    if ! echo "$token_resp" | jq empty 2>/dev/null; then
        fire_alert "audit:api-failed" "🛑 fleet-audit: OAuth token response is malformed JSON"
        return 1
    fi
    local token
    # `// empty` means jq returns "" on missing field with exit 0; the next check catches it
    token=$(echo "$token_resp" | jq -r '.access_token // empty')
    if [[ -z "$token" ]]; then
        fire_alert "audit:api-failed" "🛑 fleet-audit: OAuth response missing access_token"
        return 1
    fi

    local resp
    resp=$(curl -s -H "Authorization: Bearer $token" \
        --max-time 30 \
        -w '\n%{http_code}' \
        "https://api.tailscale.com/api/v2/tailnet/${TS_TAILNET}/devices" 2>>"$LOG_FILE") || {
        fire_alert "audit:api-failed" "🛑 fleet-audit: /devices curl invocation failed (curl exit $?)"
        return 1
    }
    http_code=$(echo "$resp" | tail -n 1)
    resp=$(echo "$resp" | sed '$d')
    if [[ "$http_code" != "200" ]]; then
        fire_alert "audit:api-failed" "🛑 fleet-audit: /devices request returned HTTP $http_code"
        return 1
    fi
    printf '%s' "$resp" > "$out_path"
    return 0
}

# --- main -------------------------------------------------------------------
if [[ -n "$DEVICES_FROM_FILE" ]]; then
    devices_json="$(cat "$DEVICES_FROM_FILE")"
else
    api_tmp=$(mktemp)
    trap 'rm -f "$api_tmp"' EXIT
    if ! get_devices_via_api "$api_tmp"; then
        # exit 0 is intentional: alert was already fired inside, and we don't want
        # cron retry to double-fire (dedup state is per-condition, not per-run)
        exit 0
    fi
    devices_json="$(cat "$api_tmp")"
    clear_alert "audit:api-failed"
fi

# Validate JSON shape before parsing
if ! echo "$devices_json" | jq empty 2>/dev/null; then
    fire_alert "audit:api-failed" "🛑 fleet-audit: /devices response is malformed JSON"
    exit 0
fi

now_epoch=$(date +%s)

is_always_on() {
    local h="$1"
    for n in "${ALWAYS_ON_NODES[@]}"; do
        [[ "$h" == "$n" ]] && return 0
    done
    return 1
}

# Iterate devices with process substitution (NOT `... | while`) so the loop runs in
# the MAIN shell. fire_alert/clear_alert hold an unreleased flock on fd 9; a pipe
# subshell would inherit that locked fd and deadlock against the parent, which is
# already holding it from the `clear_alert audit:api-failed` above. (Same subshell
# footgun documented for echo|while-read elsewhere in the fleet.)
# Match on the MagicDNS name (.name's first label — always lowercase), NOT .hostname:
# .hostname is the OS hostname ("My-MINI", "Mac Mini", even "localhost" on iOS)
# and will silently fail to match ALWAYS_ON_NODES.
while read -r dev; do
    hostname=$(echo "$dev" | jq -r '.name | split(".")[0]')
    is_always_on "$hostname" || continue

    expiry_disabled=$(echo "$dev" | jq -r '.keyExpiryDisabled')
    expires=$(echo "$dev" | jq -r '.expires')
    last_seen=$(echo "$dev" | jq -r '.lastSeen')

    # Drift detection: always-on nodes should have keyExpiryDisabled=true
    if [[ "$expiry_disabled" == "false" ]]; then
        fire_alert "$hostname:expiry-config-drifted" \
"⚠️ [$hostname] key-expiry-disabled drift detected
   keyExpiryDisabled: false (should be true on always-on nodes)
   Action: Tailscale admin → Machines → $hostname → ⋯ → Disable key expiry"
    else
        clear_alert "$hostname:expiry-config-drifted"
    fi

    # Imminent expiry — only meaningful if expiry is enabled
    if [[ "$expiry_disabled" == "false" && "$expires" != "0001-01-01T00:00:00Z" ]]; then
        expires_epoch=$(iso_to_epoch "$expires")
        if [[ -n "$expires_epoch" ]]; then
            days_left=$(( (expires_epoch - now_epoch) / 86400 ))
            if (( days_left < KEY_EXPIRY_WARN_DAYS )); then
                fire_alert "$hostname:fleet-key-expiring-soon" \
"⏰ [$hostname] Tailscale key expires in $days_left days ($expires)"
            else
                clear_alert "$hostname:fleet-key-expiring-soon"
            fi
        fi
    else
        clear_alert "$hostname:fleet-key-expiring-soon"
    fi

    # Offline thresholds (6h then 24h, both fire when offline >24h)
    last_seen_epoch=$(iso_to_epoch "$last_seen")
    if [[ -z "$last_seen_epoch" ]]; then
        # Couldn't parse the timestamp; skip offline checks for this device, log it
        log "could not parse lastSeen for $hostname: $last_seen"
        continue
    fi
    offline_seconds=$(( now_epoch - last_seen_epoch ))
    offline_hours=$(( offline_seconds / 3600 ))

    if (( offline_hours >= OFFLINE_WARN_HOURS_SECOND )); then
        fire_alert "$hostname:offline-6h"  "⚠️ [$hostname] offline for ${offline_hours}h (>6h threshold)"
        fire_alert "$hostname:offline-24h" "🛑 [$hostname] offline for ${offline_hours}h (>24h threshold)"
    elif (( offline_hours >= OFFLINE_WARN_HOURS_FIRST )); then
        fire_alert "$hostname:offline-6h"  "⚠️ [$hostname] offline for ${offline_hours}h (>6h threshold)"
        clear_alert "$hostname:offline-24h"
    else
        clear_alert "$hostname:offline-6h"
        clear_alert "$hostname:offline-24h"
    fi
done < <(echo "$devices_json" | jq -c '.devices[]')

log "fleet-audit complete: scanned ${#ALWAYS_ON_NODES[@]} always-on nodes"
