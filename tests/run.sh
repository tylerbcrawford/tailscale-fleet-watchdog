#!/bin/bash
# Run all tailscale-fleet-watchdog unit tests. Needs only bash + jq.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
echo "=== test-state-machine.sh ==="
"$DIR/test-state-machine.sh"
echo
echo "=== test-state-corruption.sh ==="
"$DIR/test-state-corruption.sh"
echo
echo "=== test-self-check.sh ==="
"$DIR/test-self-check.sh"
echo
echo "=== test-fleet-audit.sh ==="
"$DIR/test-fleet-audit.sh"
echo
echo "=== ALL TESTS PASSED ==="
