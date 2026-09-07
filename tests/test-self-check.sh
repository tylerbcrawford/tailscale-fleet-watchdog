#!/bin/bash
# Tests for tailscale-self-check.sh — uses --status-from-file to inject
# fixtures instead of calling tailscale CLI.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../bin/tailscale-self-check.sh"
FIXTURES="$SCRIPT_DIR/fixtures"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Detect GNU vs BSD date for cross-platform date math (Linux vs macOS)
if date -d '@0' >/dev/null 2>&1; then
    _DATE_FLAVOR="gnu"
else
    _DATE_FLAVOR="bsd"
fi

# Render the relative-time fixture (substitute DATE_PLACEHOLDER → now+7d)
if [[ "$_DATE_FLAVOR" == "gnu" ]]; then
    SEVEN_DAYS_AHEAD=$(date -u -d '+7 days' +"%Y-%m-%dT%H:%M:%SZ")
else
    SEVEN_DAYS_AHEAD=$(date -u -v+7d +"%Y-%m-%dT%H:%M:%SZ")
fi
sed "s|DATE_PLACEHOLDER|$SEVEN_DAYS_AHEAD|" \
    "$FIXTURES/status-key-expiring.json.template" \
    > "$TMPDIR/status-key-expiring.json"

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; exit 1; }

export TS_MONITOR_STATE_FILE="$TMPDIR/state.json"
echo '{"schema_version": 1, "alerts": {}}' > "$TS_MONITOR_STATE_FILE"

echo "Test 1: BackendState=Running, key expiry disabled or far away → no alerts"
OUTPUT=$("$SCRIPT" --status-from-file "$FIXTURES/status-running.json" 2>&1 || true)
echo "$OUTPUT" | grep -q "would fire" && fail "expected no alerts; got: $OUTPUT"
pass "healthy state produces no alerts"

echo "Test 2: BackendState=NeedsLogin → fires backend-not-running"
echo '{"schema_version": 1, "alerts": {}}' > "$TS_MONITOR_STATE_FILE"
OUTPUT=$("$SCRIPT" --status-from-file "$FIXTURES/status-needslogin.json" 2>&1 || true)
echo "$OUTPUT" | grep -q "backend-not-running" || fail "expected backend-not-running alert; got: $OUTPUT"
pass "NeedsLogin fires backend-not-running"

echo "Test 3: KeyExpiry within 14 days → fires key-expiring-soon"
echo '{"schema_version": 1, "alerts": {}}' > "$TS_MONITOR_STATE_FILE"
OUTPUT=$("$SCRIPT" --status-from-file "$TMPDIR/status-key-expiring.json" 2>&1 || true)
echo "$OUTPUT" | grep -q "key-expiring-soon" || fail "expected key-expiring-soon alert; got: $OUTPUT"
pass "key expiring within 14d fires key-expiring-soon"

echo "Test 4: already-expired key fires key-expired (not key-expiring-soon)"
echo '{"schema_version": 1, "alerts": {}}' > "$TS_MONITOR_STATE_FILE"
if [[ "$_DATE_FLAVOR" == "gnu" ]]; then
    THREE_DAYS_AGO=$(date -u -d '-3 days' +"%Y-%m-%dT%H:%M:%SZ")
else
    THREE_DAYS_AGO=$(date -u -v-3d +"%Y-%m-%dT%H:%M:%SZ")
fi
sed "s|DATE_PLACEHOLDER|$THREE_DAYS_AGO|" \
    "$FIXTURES/status-key-expired.json.template" \
    > "$TMPDIR/status-key-expired.json"
OUTPUT=$("$SCRIPT" --status-from-file "$TMPDIR/status-key-expired.json" 2>&1 || true)
echo "$OUTPUT" | grep -q "key-expired" || fail "expected key-expired alert; got: $OUTPUT"
echo "$OUTPUT" | grep -q "key-expiring-soon" && fail "should NOT fire key-expiring-soon; got: $OUTPUT"
pass "already-expired key fires key-expired"

echo "Test 5: malformed JSON from tailscale status fires cli-failed"
echo '{"schema_version": 1, "alerts": {}}' > "$TS_MONITOR_STATE_FILE"
echo '{this is not valid json' > "$TMPDIR/status-malformed.json"
OUTPUT=$("$SCRIPT" --status-from-file "$TMPDIR/status-malformed.json" 2>&1 || true)
echo "$OUTPUT" | grep -q "cli-failed" || fail "expected cli-failed; got: $OUTPUT"
pass "malformed JSON fires cli-failed"

echo "All self-check tests passed."
