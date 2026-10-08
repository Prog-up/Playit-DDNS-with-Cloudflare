#!/usr/bin/env bash
# =============================================================================
#  tests/test_sync.sh
#  Unit and regression tests for playit-sync-cloudflare.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYNC_SCRIPT="${SCRIPT_DIR}/playit-sync-cloudflare.sh"

echo "=== Running Tests for playit-sync-cloudflare ==="

# 1. Syntax check
echo "[*] Test 1: Bash syntax validation..."
bash -n "$SYNC_SCRIPT"
echo "  ✓ Syntax valid."

# 2. Help command test
echo "[*] Test 2: Help flag output..."
help_output=$("$SYNC_SCRIPT" --help)
if echo "$help_output" | grep -q "Usage:"; then
    echo "  ✓ Help flag works correctly."
else
    echo "  ✗ Help output failed."
    exit 1
fi

# 3. Missing arguments validation
echo "[*] Test 3: Missing parameters validation..."
set +e
error_output=$("$SYNC_SCRIPT" 2>&1)
exit_code=$?
set -e
if [[ $exit_code -ne 0 ]] && echo "$error_output" | grep -q "CF_API_TOKEN"; then
    echo "  ✓ Missing parameters rejected properly."
else
    echo "  ✗ Validation check failed."
    exit 1
fi

echo "=== All tests passed! ==="
