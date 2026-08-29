#!/bin/bash
# validate.sh
# End-to-end pipeline validation against a physical Proxmark3 RDV4.
#
# What it tests:
#   1. Finds the RDV4 USB serial port automatically
#   2. Runs pm3client (the cross-compiled iOS binary OR the host binary)
#      against the real device with: hf mf info
#   3. Asserts the output matches known-good card characteristics
#
# Known card under test:
#   UID  : C5 EC A5 9A
#   ATQA : 00 04
#   SAK  : 08
#   Type : Fudan FM11RF08
#   PRNG : weak
#
# Usage:
#   ./validate.sh                    # auto-detect port, use host pm3 binary
#   ./validate.sh /dev/tty.usbXXX   # explicit port
#   ./validate.sh --uid AABBCCDD    # override expected UID (different card)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PM3_SRC="${PM3_SRC:-}"
if [ -z "$PM3_SRC" ]; then
    for candidate in "$SCRIPT_DIR/../proxmark3" "$HOME/proxmark3"; do
        if [ -d "$candidate/client" ]; then
            PM3_SRC="$candidate"
            break
        fi
    done
fi
PASS=0
FAIL=0
EXPECTED_UID="C5 EC A5 9A"
EXPLICIT_PORT=""

# ── Arg parse ────────────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
    case "$1" in
        --uid) EXPECTED_UID="$2"; shift 2 ;;
        /dev/*) EXPLICIT_PORT="$1"; shift ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────

pass() { echo "  [PASS] $1"; ((PASS++)); }
fail() { echo "  [FAIL] $1"; ((FAIL++)); }

assert_contains() {
    local label="$1"
    local output="$2"
    local needle="$3"
    if echo "$output" | grep -q "$needle"; then
        pass "$label"
    else
        fail "$label — expected: '$needle'"
    fi
}

# ── Find port ─────────────────────────────────────────────────────────────────

find_port() {
    # Try the pm3 standard path first
    if [ -e /tmp/tty.usbmodemiceman1 ]; then
        echo /tmp/tty.usbmodemiceman1; return
    fi
    # Find any usbmodem device
    local ports
    ports=$(ls /dev/tty.usbmodem* 2>/dev/null || true)
    if [ -z "$ports" ]; then
        echo "ERROR: No USB serial port found. Plug in the RDV4." >&2
        exit 1
    fi
    echo "$ports" | head -1
}

PORT="${EXPLICIT_PORT:-$(find_port)}"
echo "==> Port   : $PORT"

# ── Find pm3 binary ───────────────────────────────────────────────────────────

if [ -n "$PM3_SRC" ] && [ -x "$PM3_SRC/client/proxmark3" ]; then
    PM3_BIN="$PM3_SRC/client/proxmark3"
elif command -v proxmark3 &>/dev/null; then
    PM3_BIN="$(command -v proxmark3)"
elif [ -n "$PM3_SRC" ] && [ -x "$PM3_SRC/pm3" ]; then
    # pm3 is a shell wrapper — extract the actual binary call
    # Use it directly since it handles port detection too
    PM3_BIN="$PM3_SRC/pm3"
else
    echo "ERROR: proxmark3 binary not found. Build it first." >&2
    exit 1
fi
echo "==> pm3    : $PM3_BIN"
echo "==> Card   : UID expected = $EXPECTED_UID"
echo ""

# ── Run hf mf info ────────────────────────────────────────────────────────────

echo "--- hf mf info -------------------------------------------------------"
OUTPUT=$("$PM3_BIN" -p "$PORT" -c "hf mf info" 2>&1 || true)
echo "$OUTPUT"
echo "----------------------------------------------------------------------"
echo ""

# ── Assertions ────────────────────────────────────────────────────────────────

echo "==> Asserting output..."

assert_contains "UID present"          "$OUTPUT" "$EXPECTED_UID"
assert_contains "ATQA 00 04 (1K)"      "$OUTPUT" "00 04"
assert_contains "SAK 08 (Classic 1K)"  "$OUTPUT" "SAK: 08"
assert_contains "FM11RF08 fingerprint" "$OUTPUT" "FM11RF08"
assert_contains "Weak PRNG detected"   "$OUTPUT" "weak"

# ── hw ping ───────────────────────────────────────────────────────────────────

echo ""
echo "--- hw ping ----------------------------------------------------------"
PING_OUT=$("$PM3_BIN" -p "$PORT" -c "hw ping" 2>&1 || true)
echo "$PING_OUT"
echo "----------------------------------------------------------------------"
echo ""

assert_contains "hw ping responds" "$PING_OUT" "pong"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "==> Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "==> VALIDATION PASSED" || { echo "==> VALIDATION FAILED"; exit 1; }
