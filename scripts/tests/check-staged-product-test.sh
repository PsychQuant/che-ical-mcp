#!/bin/bash
# Tests for scripts/lib/check-staged-product.sh (#238).
#
# Fixtures are tiny C programs compiled per architecture, so each failure case of
# the staged-product check can be produced on purpose. Cases that execute a fixture
# use the host's native architecture, so the script runs on Apple Silicon and Intel.
# Run: bash scripts/tests/check-staged-product-test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/check-staged-product.sh
source "$SCRIPT_DIR/../lib/check-staged-product.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-staged-product-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
HOST=$(uname -m)                                   # arm64 or x86_64
OTHER=$([ "$HOST" = arm64 ] && echo x86_64 || echo arm64)

# fixture <name> <arch> <stdout first line> [exit code] [stderr line]
fixture() {
    local name="$1" arch="$2" line="$3" code="${4:-0}" err="${5:-}"
    local errstmt=""
    [ -n "$err" ] && errstmt="fputs(\"$err\\n\", stderr);"
    printf '#include <stdio.h>\nint main(void){%sputs("%s");puts("build: test");return %s;}\n' \
        "$errstmt" "$line" "$code" > "$TMP/$name.c"
    clang -arch "$arch" -o "$TMP/$name" "$TMP/$name.c" 2>/dev/null || { echo "cannot build fixture $name for $arch"; exit 2; }
}

# expect <pass|fail> <description> <output substring or ""> -- <command...>
expect() {
    [ "$#" -ge 5 ] && [ "$4" = -- ] || { echo "harness error: expect needs <want> <desc> <needle> -- <cmd...>"; exit 2; }
    local want="$1" desc="$2" needle="$3"; shift 4
    local out rc
    out=$("$@" 2>&1) && rc=0 || rc=$?
    if { [ "$want" = pass ] && [ $rc -eq 0 ]; } || { [ "$want" = fail ] && [ $rc -ne 0 ]; }; then
        if [ -n "$needle" ] && [[ "$out" != *"$needle"* ]]; then
            echo "✗ $desc — output lacks '$needle': $out"; FAIL=$((FAIL+1)); return
        fi
        echo "✓ $desc"; PASS=$((PASS+1))
    else
        echo "✗ $desc — expected $want, got rc=$rc: $out"; FAIL=$((FAIL+1))
    fi
}

fixture good       "$HOST"  "CheICalMCP 1.2.3"
fixture good-other "$OTHER" "CheICalMCP 1.2.3"
fixture older      "$HOST"  "CheICalMCP 1.2.2"
fixture longer     "$HOST"  "CheICalMCP 11.2.3"
fixture suffixed   "$HOST"  "CheICalMCP 1.2.3-dev"
fixture wrong-name "$HOST"  "Other 1.2.3"
fixture crash      "$HOST"  "CheICalMCP 1.2.3" 3
fixture noisy      "$HOST"  "CheICalMCP 1.2.3" 0 "warning: something on stderr"
lipo -create "$TMP/good" "$TMP/good-other" -output "$TMP/fat"
echo "not a Mach-O file" > "$TMP/text"

C=check_staged_product
expect fail "missing product is refused"             "no $HOST product" -- $C "$TMP/does-not-exist" "$HOST" CheICalMCP 1.2.3
expect fail "unreadable (non-Mach-O) product"        "cannot read the architectures" -- $C "$TMP/text" "$HOST" CheICalMCP 1.2.3
expect fail "product of another architecture"        "contains '$HOST', expected '$OTHER'" -- $C "$TMP/good" "$OTHER" CheICalMCP 1.2.3
expect fail "product with two architectures"         "expected '$HOST'" -- $C "$TMP/fat" "$HOST" CheICalMCP 1.2.3
expect fail "product reporting an older version"     "reports 'CheICalMCP 1.2.2'" -- $C "$TMP/older" "$HOST" CheICalMCP 1.2.3
expect fail "version that only ends with the expected one" "reports 'CheICalMCP 11.2.3'" -- $C "$TMP/longer" "$HOST" CheICalMCP 1.2.3
expect fail "version with a suffix"                  "reports 'CheICalMCP 1.2.3-dev'" -- $C "$TMP/suffixed" "$HOST" CheICalMCP 1.2.3
expect fail "another binary name"                    "reports 'Other 1.2.3'" -- $C "$TMP/wrong-name" "$HOST" CheICalMCP 1.2.3
expect fail "product that does not run cleanly"      "could not be run (exit 3)" -- $C "$TMP/crash" "$HOST" CheICalMCP 1.2.3
expect pass "matching product, extra stdout lines ignored" "$HOST product reports CheICalMCP 1.2.3" -- $C "$TMP/good" "$HOST" CheICalMCP 1.2.3
expect pass "stderr output does not affect the version line" "$HOST product reports CheICalMCP 1.2.3" -- $C "$TMP/noisy" "$HOST" CheICalMCP 1.2.3

if host_can_execute_arch "$OTHER"; then
    expect pass "matching $OTHER product" "$OTHER product reports CheICalMCP 1.2.3" -- $C "$TMP/good-other" "$OTHER" CheICalMCP 1.2.3
else
    echo "- skipped: this host cannot execute $OTHER (no Rosetta on Apple Silicon, or an Intel host)"
fi

# An architecture the host cannot execute: a visible note by default, a failure in
# strict mode (the release path). Simulated by overriding the probe.
host_can_execute_arch() { return 1; }
expect pass "unexecutable architecture: note by default" "version is not checked" -- $C "$TMP/older" "$HOST" CheICalMCP 1.2.3
CHECK_STAGED_STRICT=1 expect fail "unexecutable architecture: failure in strict mode" "cannot be checked on this host" -- \
    $C "$TMP/good" "$HOST" CheICalMCP 1.2.3

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
