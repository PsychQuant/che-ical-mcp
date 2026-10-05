#!/bin/bash
# Tests for scripts/lib/check-staged-product.sh (#238).
#
# Fixtures are tiny C programs compiled per architecture, so each failure case of
# the staged-product check can be produced on purpose: a missing product, a product
# of the wrong (or more than one) architecture, a product that reports another
# version, and a product that cannot run. Run: bash scripts/tests/check-staged-product-test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/check-staged-product.sh
source "$SCRIPT_DIR/../lib/check-staged-product.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-staged-product-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

fixture() {  # fixture <name> <arch> <first line> [exit code]
    local name="$1" arch="$2" line="$3" code="${4:-0}"
    printf '#include <stdio.h>\nint main(void){puts("%s");puts("build: test");return %s;}\n' "$line" "$code" > "$TMP/$name.c"
    clang -arch "$arch" -o "$TMP/$name" "$TMP/$name.c" 2>/dev/null || { echo "cannot build fixture $name for $arch"; exit 2; }
}

expect() {  # expect <pass|fail> <description> <message substring or ""> -- <command...>
    local want="$1" desc="$2" needle="$3"; shift 4
    local out rc
    out=$("$@" 2>&1); rc=$?
    if { [ "$want" = pass ] && [ $rc -eq 0 ]; } || { [ "$want" = fail ] && [ $rc -ne 0 ]; }; then
        if [ -n "$needle" ] && [[ "$out" != *"$needle"* ]]; then
            echo "✗ $desc — output lacks '$needle': $out"; FAIL=$((FAIL+1)); return
        fi
        echo "✓ $desc"; PASS=$((PASS+1))
    else
        echo "✗ $desc — expected $want, got rc=$rc: $out"; FAIL=$((FAIL+1))
    fi
}

fixture good-arm64  arm64  "CheICalMCP 1.2.3"
fixture good-x86_64 x86_64 "CheICalMCP 1.2.3"
fixture old-arm64   arm64  "CheICalMCP 1.2.2"
fixture crash-arm64 arm64  "CheICalMCP 1.2.3" 3
lipo -create "$TMP/good-arm64" "$TMP/good-x86_64" -output "$TMP/fat"

expect fail "missing product is refused"        "no arm64 product" -- \
    check_staged_product "$TMP/does-not-exist" arm64 CheICalMCP 1.2.3
expect fail "product of another architecture"   "contains 'arm64', expected 'x86_64'" -- \
    check_staged_product "$TMP/good-arm64" x86_64 CheICalMCP 1.2.3
expect fail "product with two architectures"    "expected 'arm64'" -- \
    check_staged_product "$TMP/fat" arm64 CheICalMCP 1.2.3
expect fail "product reporting an older version" "reports 'CheICalMCP 1.2.2'" -- \
    check_staged_product "$TMP/old-arm64" arm64 CheICalMCP 1.2.3
expect fail "product that does not run cleanly"  "could not be run" -- \
    check_staged_product "$TMP/crash-arm64" arm64 CheICalMCP 1.2.3
expect pass "matching arm64 product (extra output lines ignored)" "" -- \
    check_staged_product "$TMP/good-arm64" arm64 CheICalMCP 1.2.3

if host_can_execute_arch x86_64; then
    expect pass "matching x86_64 product" "" -- \
        check_staged_product "$TMP/good-x86_64" x86_64 CheICalMCP 1.2.3
else
    echo "- skipped: this host cannot execute x86_64 (no Rosetta)"
fi

# An architecture the host cannot execute is not passed silently: the version
# check is skipped with a visible note. Simulated by overriding the probe.
host_can_execute_arch() { return 1; }
expect pass "unexecutable architecture is reported, not hidden" "version not checked" -- \
    check_staged_product "$TMP/good-arm64" arm64 CheICalMCP 1.2.3

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
