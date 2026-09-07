#!/bin/bash
# Tests for tailscale-fleet-audit.sh — uses --devices-from-file to inject
# fixtures instead of hitting the Tailscale REST API.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$SCRIPT_DIR/../bin/tailscale-fleet-audit.sh"
export ALWAYS_ON_NODES="media-server vps mac-mini"
export TS_WATCHDOG_CONFIG=/dev/null
FIXTURES="$SCRIPT_DIR/fixtures"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

# Detect GNU vs BSD date for cross-platform fixture rendering
if date -d '@0' >/dev/null 2>&1; then
    _DATE_FLAVOR="gnu"
else
    _DATE_FLAVOR="bsd"
fi

# Render relative timestamps into placeholders
if [[ "$_DATE_FLAVOR" == "gnu" ]]; then
    RECENT=$(date -u -d '-1 hour' +"%Y-%m-%dT%H:%M:%SZ")
    OLD=$(date -u -d '-3 days' +"%Y-%m-%dT%H:%M:%SZ")
    OFFLINE_30H=$(date -u -d '-30 hours' +"%Y-%m-%dT%H:%M:%SZ")
    EXPIRY_SOON=$(date -u -d '+7 days' +"%Y-%m-%dT%H:%M:%SZ")
else
    RECENT=$(date -u -v-1H +"%Y-%m-%dT%H:%M:%SZ")
    OLD=$(date -u -v-3d +"%Y-%m-%dT%H:%M:%SZ")
    OFFLINE_30H=$(date -u -v-30H +"%Y-%m-%dT%H:%M:%SZ")
    EXPIRY_SOON=$(date -u -v+7d +"%Y-%m-%dT%H:%M:%SZ")
fi

render_fixture() {
    local src="$1" dst="$2"
    sed -e "s|RECENT_PLACEHOLDER|$RECENT|g" \
        -e "s|OLD_PLACEHOLDER|$OLD|g" \
        -e "s|OFFLINE_30H_PLACEHOLDER|$OFFLINE_30H|g" \
        -e "s|EXPIRY_SOON_PLACEHOLDER|$EXPIRY_SOON|g" \
        "$src" > "$dst"
}

pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; exit 1; }

export TS_MONITOR_STATE_FILE="$TMPDIR/state.json"
echo '{"schema_version": 1, "alerts": {}}' > "$TS_MONITOR_STATE_FILE"

echo "Test 1: healthy fleet → no alerts (laptop offline+expiry-on is ignored)"
render_fixture "$FIXTURES/devices-healthy.json" "$TMPDIR/devices.json"
OUTPUT=$("$SCRIPT" --devices-from-file "$TMPDIR/devices.json" 2>&1 || true)
echo "$OUTPUT" | grep -q "would fire" && fail "expected no alerts; got: $OUTPUT"
pass "healthy fleet — laptop offline does NOT alert"

echo "Test 2: drift on media-server → fires expiry-config-drifted + fleet-key-expiring-soon"
echo '{"schema_version": 1, "alerts": {}}' > "$TS_MONITOR_STATE_FILE"
render_fixture "$FIXTURES/devices-drifted.json" "$TMPDIR/devices.json"
OUTPUT=$("$SCRIPT" --devices-from-file "$TMPDIR/devices.json" 2>&1 || true)
echo "$OUTPUT" | grep -q "media-server:expiry-config-drifted" || fail "expected drift alert; got: $OUTPUT"
echo "$OUTPUT" | grep -q "media-server:fleet-key-expiring-soon" || fail "expected fleet-key-expiring-soon; got: $OUTPUT"
pass "drift on always-on node fires both keys"

echo "Test 3: mac-mini offline >24h → fires offline-6h AND offline-24h"
echo '{"schema_version": 1, "alerts": {}}' > "$TS_MONITOR_STATE_FILE"
render_fixture "$FIXTURES/devices-offline-24h.json" "$TMPDIR/devices.json"
OUTPUT=$("$SCRIPT" --devices-from-file "$TMPDIR/devices.json" 2>&1 || true)
echo "$OUTPUT" | grep -q "mac-mini:offline-6h"  || fail "expected offline-6h; got: $OUTPUT"
echo "$OUTPUT" | grep -q "mac-mini:offline-24h" || fail "expected offline-24h; got: $OUTPUT"
pass "always-on node offline >24h fires both keys"

echo "Test 4: laptop (laptop) NOT in ALWAYS_ON_NODES → no alerts even with old lastSeen"
echo '{"schema_version": 1, "alerts": {}}' > "$TS_MONITOR_STATE_FILE"
render_fixture "$FIXTURES/devices-healthy.json" "$TMPDIR/devices.json"
OUTPUT=$("$SCRIPT" --devices-from-file "$TMPDIR/devices.json" 2>&1 || true)
echo "$OUTPUT" | grep -q "laptop" && fail "laptop should NOT appear in any alert; got: $OUTPUT"
pass "laptop (intermittent class) is excluded from all alerts"

echo "Test 5: malformed devices JSON → fires audit:api-failed"
echo '{"schema_version": 1, "alerts": {}}' > "$TS_MONITOR_STATE_FILE"
echo '{this is not valid json' > "$TMPDIR/devices.json"
OUTPUT=$("$SCRIPT" --devices-from-file "$TMPDIR/devices.json" 2>&1 || true)
echo "$OUTPUT" | grep -q "audit:api-failed" || fail "expected audit:api-failed; got: $OUTPUT"
pass "malformed devices JSON fires audit:api-failed"

echo "All fleet-audit tests passed."
