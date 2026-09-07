#!/bin/bash
# Unit tests for tailscale-monitor-lib.sh state machine.
# Each test sets up a temp state file, sources the lib, calls functions, asserts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/../lib/state-machine.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Capture webhook calls instead of actually sending
DISCORD_TEST_LOG="$TMPDIR/discord-calls.log"
discord_send_alert() {
    echo "$@" >> "$DISCORD_TEST_LOG"
}
export -f discord_send_alert

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; exit 1; }

# Source the lib with our state file pointing at temp
export TS_MONITOR_STATE_FILE="$TMPDIR/state.json"
source "$LIB"

echo "Test 1: fire_alert on empty state writes new entry and sends webhook"
cp "$FIXTURES/empty-state.json" "$TS_MONITOR_STATE_FILE"
fire_alert "media-server:backend-not-running" "test message"
[[ -s "$DISCORD_TEST_LOG" ]] || fail "expected webhook called"
jq -e '.alerts["media-server:backend-not-running"].cleared == false' "$TS_MONITOR_STATE_FILE" >/dev/null \
    || fail "expected state entry with cleared=false"
pass "fire_alert wrote state and called webhook"

echo "Test 2: fire_alert on already-fired-not-cleared is silent"
cp "$FIXTURES/fired-not-cleared.json" "$TS_MONITOR_STATE_FILE"
> "$DISCORD_TEST_LOG"
fire_alert "media-server:backend-not-running" "test message"
[[ ! -s "$DISCORD_TEST_LOG" ]] || fail "expected no webhook call (dedup)"
pass "fire_alert deduped on already-fired"

echo "Test 3: fire_alert on already-fired-AND-cleared fires again"
cp "$FIXTURES/fired-and-cleared.json" "$TS_MONITOR_STATE_FILE"
> "$DISCORD_TEST_LOG"
fire_alert "media-server:backend-not-running" "test message"
[[ -s "$DISCORD_TEST_LOG" ]] || fail "expected webhook (re-fire after clear)"
jq -e '.alerts["media-server:backend-not-running"].cleared == false' "$TS_MONITOR_STATE_FILE" >/dev/null \
    || fail "expected cleared=false after re-fire"
pass "fire_alert re-fires after clear"

echo "Test 4: clear_alert on fired-not-cleared sets cleared=true silently"
cp "$FIXTURES/fired-not-cleared.json" "$TS_MONITOR_STATE_FILE"
> "$DISCORD_TEST_LOG"
clear_alert "media-server:backend-not-running"
[[ ! -s "$DISCORD_TEST_LOG" ]] || fail "expected no webhook on clear (silent recovery)"
jq -e '.alerts["media-server:backend-not-running"].cleared == true' "$TS_MONITOR_STATE_FILE" >/dev/null \
    || fail "expected cleared=true"
pass "clear_alert silently marks cleared"

echo "Test 5: clear_alert on already-cleared is a no-op"
cp "$FIXTURES/fired-and-cleared.json" "$TS_MONITOR_STATE_FILE"
BEFORE=$(jq -r '.alerts["media-server:backend-not-running"].cleared_at' "$TS_MONITOR_STATE_FILE")
sleep 1
clear_alert "media-server:backend-not-running"
AFTER=$(jq -r '.alerts["media-server:backend-not-running"].cleared_at' "$TS_MONITOR_STATE_FILE")
[[ "$BEFORE" == "$AFTER" ]] || fail "expected cleared_at unchanged"
pass "clear_alert is no-op when already cleared"

echo "Test 6: two distinct keys can both be fired and tracked separately"
cp "$FIXTURES/empty-state.json" "$TS_MONITOR_STATE_FILE"
> "$DISCORD_TEST_LOG"
fire_alert "media-server:backend-not-running" "first alert"
fire_alert "media-server:key-expiring-soon" "second alert"
LINES=$(wc -l < "$DISCORD_TEST_LOG")
[[ "$LINES" -eq 2 ]] || fail "expected 2 webhook calls for 2 distinct keys, got $LINES"
jq -e '.alerts | length == 2' "$TS_MONITOR_STATE_FILE" >/dev/null \
    || fail "expected 2 alert entries in state"
pass "two distinct keys coexist independently"

echo "Test 7: dry-run mode writes state but does NOT call webhook"
cp "$FIXTURES/empty-state.json" "$TS_MONITOR_STATE_FILE"
> "$DISCORD_TEST_LOG"
TS_MONITOR_DRY_RUN=1 fire_alert "media-server:dry-run-test" "should not actually fire"
[[ ! -s "$DISCORD_TEST_LOG" ]] || fail "expected no real webhook in dry-run"
jq -e '.alerts["media-server:dry-run-test"].cleared == false' "$TS_MONITOR_STATE_FILE" >/dev/null \
    || fail "expected state entry written even in dry-run (dedup must work)"
pass "dry-run writes state but skips webhook"

echo "All state-machine tests passed."
