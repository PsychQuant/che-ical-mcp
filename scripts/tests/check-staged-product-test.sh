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

# --- one signing decision: it chooses both signing and strict checking ---
# ids=yes|no: whether the keychain holds the identity. Only the security binary is
# replaced (by a script that answers the same find-identity call); the lookup is real.
printf '#!/bin/sh\n[ "$1 $2 $3 $4" = "find-identity -p codesigning -v" ] || exit 1\n[ "$FAKE_IDS" = yes ] && echo "  1) F25 \\"Developer ID Application: Test (ABC)\\""\nexit 0\n' > "$TMP/fake-security"
chmod +x "$TMP/fake-security"
rb() { ( unset REQUIRE_CODESIGN SKIP_CODESIGN DEVELOPER_ID SHOULD_SIGN; export FAKE_IDS=no
         for kv in "$@"; do case "$kv" in ids=*) FAKE_IDS="${kv#ids=}" ;; *) export "$kv" ;; esac; done
         CSP_SECURITY="$TMP/fake-security"
         csp_decide_signing
         if csp_release_build; then echo "strict sign=$SHOULD_SIGN"; else echo "lenient sign=$SHOULD_SIGN ($SKIP_REASON)"; fi ); }
expect pass "REQUIRE_CODESIGN=1 is a release build"     "strict"  -- rb REQUIRE_CODESIGN=1
expect pass "REQUIRE_CODESIGN=true is a release build"  "strict"  -- rb REQUIRE_CODESIGN=true
expect pass "DEVELOPER_ID in the keychain: signed and strict" "strict sign=true" -- rb DEVELOPER_ID=ABC ids=yes
expect pass "DEVELOPER_ID not in the keychain: unsigned, so not strict" "lenient sign=false (codesigning identity 'ABC' not in keychain)" -- rb DEVELOPER_ID=ABC
expect pass "SKIP_CODESIGN=true wins over DEVELOPER_ID" "lenient sign=false (SKIP_CODESIGN=true)" -- rb DEVELOPER_ID=ABC SKIP_CODESIGN=true ids=yes
expect pass "REQUIRE_CODESIGN=0 alone is not"           "lenient" -- rb REQUIRE_CODESIGN=0
expect pass "no signing inputs is not"                  "lenient sign=false (DEVELOPER_ID env not set)" -- rb
expect pass "strict when no signing decision was made"  "strict" -- \
    bash -c "unset SHOULD_SIGN REQUIRE_CODESIGN; source '$SCRIPT_DIR/../lib/check-staged-product.sh'; csp_release_build 2>/dev/null && echo strict || echo lenient"

# --- packaged slices must be the checked ones; the final file is checked again ---
fixture arm-good    arm64  "CheICalMCP 1.2.3"
fixture x86-good    x86_64 "CheICalMCP 1.2.3"
fixture arm-old     arm64  "CheICalMCP 1.2.2"
STAGE="$TMP/stage"; mkdir -p "$STAGE"
cp "$TMP/arm-good" "$STAGE/CheICalMCP-arm64"; cp "$TMP/x86-good" "$STAGE/CheICalMCP-x86_64"
lipo -create "$TMP/arm-good" "$TMP/x86-good" -output "$TMP/universal-good"
lipo -create "$TMP/arm-old"  "$TMP/x86-good" -output "$TMP/universal-swapped"
expect pass "packaged slices match the checked products" "slices match" -- check_packaged_slices "$TMP/universal-good" "$STAGE" CheICalMCP
expect fail "a packaged slice that differs is refused"   "arm64 slice" -- check_packaged_slices "$TMP/universal-swapped" "$STAGE" CheICalMCP
expect fail "a universal binary missing a slice"         "x86_64" -- check_packaged_slices "$TMP/arm-good" "$STAGE" CheICalMCP
fixture e-good      arm64e "CheICalMCP 1.2.3"
lipo -create "$TMP/arm-good" "$TMP/x86-good" "$TMP/e-good" -output "$TMP/universal-three"
expect fail "a universal binary with an extra slice is refused" "expected exactly arm64 and x86_64" -- check_packaged_slices "$TMP/universal-three" "$STAGE" CheICalMCP
expect pass "final binary reports the version"           "($HOST) reports CheICalMCP 1.2.3" -- check_final_binary "$TMP/universal-good" CheICalMCP 1.2.3
# The final file must still be the two-slice universal binary that was checked.
expect fail "a final binary that lost a slice is refused" "expected exactly arm64 and x86_64" -- check_final_binary "$TMP/arm-good" CheICalMCP 1.2.3
expect fail "a final binary with an extra slice is refused" "expected exactly arm64 and x86_64" -- check_final_binary "$TMP/universal-three" CheICalMCP 1.2.3
# A stale slice of the host's own architecture fails on any host (Apple Silicon or Intel).
fixture host-old "$HOST" "CheICalMCP 1.2.2"
other_good=$([ "$HOST" = arm64 ] && echo "$TMP/x86-good" || echo "$TMP/arm-good")
lipo -create "$TMP/host-old" "$other_good" -output "$TMP/universal-stale-host"
expect fail "final binary with a stale host slice"       "reports 'CheICalMCP 1.2.2'" -- check_final_binary "$TMP/universal-stale-host" CheICalMCP 1.2.3

# --- artifacts from an earlier run are removed before a build and after a failed gate ---
ART="$TMP/art"; mkdir -p "$ART/server"
for f in "che-ical-mcp-1.2.3.mcpb" "che-ical-mcp-1.2.3.mcpb.sha256" "server/CheICalMCP" "server/CheICalMCP.sha256" "che-ical-mcp-1.2.2.mcpb" "manifest.json"; do
    echo old > "$ART/$f"
done
csp_clear_release_artifacts "$ART/che-ical-mcp-1.2.3.mcpb" "$ART/server/CheICalMCP"
left=$(cd "$ART" && find . -type f | sort | tr '\n' ' ')
if [ "$left" = "./che-ical-mcp-1.2.2.mcpb ./manifest.json " ]; then
    echo "✓ release artifacts of this version are cleared, nothing else"; PASS=$((PASS+1))
else
    echo "✗ release artifacts of this version are cleared, nothing else — left: $left"; FAIL=$((FAIL+1))
fi
echo old > "$ART/.sha256"
( cd "$ART" && csp_clear_release_artifacts "" "" )
if [ -f "$ART/.sha256" ]; then echo "✓ an empty path removes nothing"; PASS=$((PASS+1))
else echo "✗ an empty path removes nothing — .sha256 was deleted"; FAIL=$((FAIL+1)); fi

# csp_arm_cleanup: a run that ends non-zero or is interrupted removes the files; a
# successful run keeps them. Run as a real bash process, the way build-mcpb.sh runs.
armed() {   # armed <how the run ends> -> prints "kept" or "removed"
    local d="$TMP/armed-$RANDOM"; mkdir -p "$d"; echo x > "$d/a.mcpb"; echo x > "$d/a.mcpb.sha256"; echo x > "$d/bin"; echo x > "$d/bin.sha256"
    bash -c "source '$SCRIPT_DIR/../lib/check-staged-product.sh'; PACKED_MCPB='$d/a.mcpb'; UNIVERSAL_BINARY='$d/bin'; csp_arm_cleanup; $1" >/dev/null 2>&1
    if [ -z "$(ls -A "$d")" ]; then echo removed; elif [ "$(ls "$d" | wc -l | tr -d ' ')" = 4 ]; then echo kept; else echo "partly: $(ls "$d" | tr '\n' ' ')"; fi
}
expect pass "a successful run keeps its files"           "kept"    -- armed "exit 0"
expect pass "a failed run removes its files"             "removed" -- armed "exit 3"
expect pass "a set -e abort removes its files"           "removed" -- armed "set -e; false"
expect pass "a run stopped with TERM removes its files"  "removed" -- armed 'kill -TERM $$; sleep 2'
expect pass "a run stopped with INT removes its files"   "removed" -- armed 'kill -INT $$; sleep 2'
expect pass "a run stopped with HUP removes its files"   "removed" -- armed 'kill -HUP $$; sleep 2'

# --- the pass/fail tools are not taken from PATH; messages are cleaned ---
mkdir -p "$TMP/shim"; printf '#!/bin/sh\necho %s\n' "$OTHER" > "$TMP/shim/lipo"; chmod +x "$TMP/shim/lipo"
expect pass "a lipo shim earlier in PATH does not change the verdict" "$HOST product reports" -- \
    env PATH="$TMP/shim:$PATH" bash -c "source '$SCRIPT_DIR/../lib/check-staged-product.sh'; check_staged_product '$TMP/good' '$HOST' CheICalMCP 1.2.3"
# 2000 characters of output: the message must hold at most 300 of them, so a missing
# truncation cannot slip under the length bound.
printf '#include <stdio.h>\nint main(void){printf("\\033[31mX%%02000d\\n", 0);return 4;}\n' > "$TMP/ctl.c"
clang -arch "$HOST" -o "$TMP/ctl" "$TMP/ctl.c" 2>/dev/null || { echo "cannot build fixture ctl for $HOST"; exit 2; }
ctl_msg=$(check_staged_product "$TMP/ctl" "$HOST" CheICalMCP 1.2.3 2>&1)
ctl_body=${ctl_msg//"$TMP"/}                       # the temp path may contain zeros too
ctl_zeros=$(printf '%s' "$ctl_body" | tr -cd '0' | wc -c)
if [[ "$ctl_msg" == *$'\033'* ]] || [ "$ctl_zeros" -gt 300 ] || [ $(( ${#ctl_body} - ctl_zeros )) -gt 400 ]; then
    echo "✗ binary output in messages is cleaned and truncated — got ${#ctl_msg} chars"; FAIL=$((FAIL+1))
else
    echo "✓ binary output in messages is cleaned and truncated"; PASS=$((PASS+1))
fi

# An architecture the host cannot execute: a visible note by default, a failure in
# strict mode (the release path). Simulated by overriding the probe.
host_can_execute_arch() { return 1; }
expect pass "unexecutable architecture: note by default" "version is not checked" -- $C "$TMP/older" "$HOST" CheICalMCP 1.2.3
CHECK_STAGED_STRICT=1 expect fail "unexecutable architecture: failure in strict mode" "cannot be checked on this host" -- \
    $C "$TMP/good" "$HOST" CheICalMCP 1.2.3

# --- build-mcpb.sh run in a scratch project (never the repo's own mcpb/): the top of the
# script refuses an unsignable REQUIRE_CODESIGN build before building and clears this
# version's files; a swift shim records whether a build started ---
PROJ="$TMP/proj"; mkdir -p "$PROJ/Sources/CheICalMCP" "$PROJ/mcpb/server" "$PROJ/bin"
cp -R "$SCRIPT_DIR/.." "$PROJ/scripts"
printf 'enum AppVersion { static let current = "1.2.3" }\n' > "$PROJ/Sources/CheICalMCP/Version.swift"
printf '#!/bin/sh\ntouch "%s/swift-ran"\nexit 1\n' "$PROJ" > "$PROJ/bin/swift"; chmod +x "$PROJ/bin/swift"
for f in che-ical-mcp-1.2.3.mcpb che-ical-mcp-1.2.3.mcpb.sha256 server/CheICalMCP server/CheICalMCP.sha256; do echo old > "$PROJ/mcpb/$f"; done
proj_out=$(cd "$PROJ" && REQUIRE_CODESIGN=1 SKIP_CODESIGN=1 PATH="$PROJ/bin:$PATH" bash scripts/build-mcpb.sh 2>&1); proj_rc=$?
if [ "$proj_rc" -ne 0 ] && [[ "$proj_out" == *"Refusing to skip signing"* ]] && [ ! -e "$PROJ/swift-ran" ] && [ -z "$(ls -A "$PROJ/mcpb/server")" ] && [ ! -e "$PROJ/mcpb/che-ical-mcp-1.2.3.mcpb" ] && [ ! -e "$PROJ/mcpb/che-ical-mcp-1.2.3.mcpb.sha256" ]; then
    echo "✓ build-mcpb.sh refuses an unsignable REQUIRE_CODESIGN build before building, and clears this version's files"; PASS=$((PASS+1))
else
    echo "✗ build-mcpb.sh refuses an unsignable REQUIRE_CODESIGN build before building (rc=$proj_rc, swift ran: $([ -e "$PROJ/swift-ran" ] && echo yes || echo no), left: $(cd "$PROJ/mcpb" && find . -type f | tr '\n' ' '))"; FAIL=$((FAIL+1))
fi

# --- build-mcpb.sh wiring: each check is called, in the right place (#238) ---
B="$SCRIPT_DIR/../build-mcpb.sh"
first() { grep -nE -- "$1" "$B" | head -1 | cut -d: -f1; }
wired() {   # wired <description> <pattern A> <pattern B>: A appears, B appears, A before B
    local a b; a=$(first "$2"); b=$(first "$3")
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]; then echo "✓ wiring: $1"; PASS=$((PASS+1))
    else echo "✗ wiring: $1 (lines '$a' / '$b')"; FAIL=$((FAIL+1)); fi
}
wired "cleanup is armed before anything is built"     '^csp_arm_cleanup$'                       '^echo "\[1/7\]'
wired "cleanup is armed before the version is read"    '^csp_arm_cleanup$'                       '^SOURCE_VERSION='
wired "old artifacts are cleared before anything is built" '^csp_clear_release_artifacts "\$PACKED_MCPB" "\$UNIVERSAL_BINARY"$' '^echo "\[1/7\]'
wired "the version is read before the clear"           '^SOURCE_VERSION='                        '^csp_clear_release_artifacts '
wired "the signing decision is made before anything is built" '^csp_decide_signing$'           '^echo "\[1/7\]'
wired "strict mode is chosen after the decision"       '^csp_decide_signing$'                    '^if csp_release_build; then$'
wired "an unsignable REQUIRE_CODESIGN build is refused before building" 'Refusing to skip signing' '^echo "\[1/7\]'
wired "packaged slices are checked after lipo"         '^lipo -create '                          '^check_packaged_slices .* \|\| exit 1$'
wired "the final binary is checked after signing"      'sign-and-notarize.sh" "\$UNIVERSAL_BINARY"' '^check_final_binary .* \|\| exit 1$'
wired "the final binary is checked before packing"     '^check_final_binary .* \|\| exit 1$'   'mcpb pack '
if [ "$(grep -A1 -E '^if csp_release_build; then$' "$B" | sed -n 2p | tr -d ' ')" = "exportCHECK_STAGED_STRICT=1" ]; then
    echo "✓ wiring: the strict branch exports CHECK_STAGED_STRICT=1"; PASS=$((PASS+1))
else
    echo "✗ wiring: the strict branch exports CHECK_STAGED_STRICT=1"; FAIL=$((FAIL+1))
fi
if grep -vE '^[[:space:]]*#' "$B" | grep -qE 'SHOULD_SIGN='; then
    echo "✗ wiring: build-mcpb.sh makes a second signing decision"; FAIL=$((FAIL+1))
else
    echo "✓ wiring: build-mcpb.sh has no second signing decision"; PASS=$((PASS+1))
fi
if grep -qE '^[[:space:]]*trap[[:space:]]' "$B"; then
    echo "✗ wiring: build-mcpb.sh sets its own trap (it would replace the cleanup trap)"; FAIL=$((FAIL+1))
else
    echo "✓ wiring: build-mcpb.sh sets no trap of its own"; PASS=$((PASS+1))
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
