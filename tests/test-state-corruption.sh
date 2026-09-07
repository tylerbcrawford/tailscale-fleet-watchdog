#!/bin/bash
# Verify corrupt state.json is reset cleanly + meta:state-reset alert fires once.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../lib/state-machine.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

DISCORD_TEST_LOG="$TMPDIR/discord-calls.log"
discord_send_alert() { echo "$@" >> "$DISCORD_TEST_LOG"; }
export -f discord_send_alert

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; exit 1; }

export TS_MONITOR_STATE_FILE="$TMPDIR/state.json"
cp "$FIXTURES/corrupt-state.json" "$TS_MONITOR_STATE_FILE"
# shellcheck source=/dev/null
source "$LIB"

echo "Test 1: corrupt state file is reset to empty + meta:state-reset fires once"
fire_alert "media-server:key-expiring-soon" "12 days left"
# Should have TWO webhook calls: meta:state-reset + the actual alert
LINES=$(wc -l < "$DISCORD_TEST_LOG")
[[ "$LINES" -eq 2 ]] || fail "expected 2 webhook calls, got $LINES"
grep -q "state-reset" "$DISCORD_TEST_LOG" || fail "expected meta:state-reset alert"
jq -e '.schema_version == 1' "$TS_MONITOR_STATE_FILE" >/dev/null || fail "state file not reset to valid JSON"
pass "corrupt state file reset cleanly with single meta:state-reset alert"

echo "Test 2: subsequent runs do not re-fire meta:state-reset"
cp "$FIXTURES/corrupt-state.json" "$TS_MONITOR_STATE_FILE"
: > "$DISCORD_TEST_LOG"
fire_alert "media-server:key-expiring-soon" "12 days left"  # First call: triggers reset
: > "$DISCORD_TEST_LOG"
fire_alert "media-server:cli-failed" "different alert"      # Second call: should not re-fire reset
grep -q "state-reset" "$DISCORD_TEST_LOG" && fail "meta:state-reset should not re-fire"
pass "meta:state-reset deduped after first reset"

echo "All state-corruption tests passed."
