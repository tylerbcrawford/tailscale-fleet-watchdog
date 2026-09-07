#!/bin/bash
# notify.sh — minimal Discord-compatible webhook sender.
#
# Sourced by bin/*.sh. Provides:
#   send_webhook_alert <title> <body>
#
# Env:
#   WEBHOOK_URL        (required) Discord webhook URL. Any service that accepts
#                      Discord-style JSON embeds works (e.g. a relay you own).
#   WEBHOOK_USERNAME   (optional) display name for the post, default "tailscale-watchdog"
#
# Uses jq to build the payload so multi-line bodies, quotes and backslashes are
# escaped correctly — a plain heredoc-interpolated payload returns HTTP 400 on
# the first multi-line message.

send_webhook_alert() {
    local title="$1" body="$2"
    if [[ -z "${WEBHOOK_URL:-}" ]]; then
        echo "notify: WEBHOOK_URL is not set; alert not sent: $title" >&2
        return 1
    fi
    local payload
    payload=$(jq -n \
        --arg username "${WEBHOOK_USERNAME:-tailscale-watchdog}" \
        --arg title "$title" \
        --arg description "$body" \
        --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{username: $username,
          embeds: [{title: $title, description: $description, color: 15158332, timestamp: $timestamp}]}')
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 15 \
        -H "Content-Type: application/json" -d "$payload" "$WEBHOOK_URL") || return 1
    [[ "$code" == 2* ]] || { echo "notify: webhook returned HTTP $code" >&2; return 1; }
}
