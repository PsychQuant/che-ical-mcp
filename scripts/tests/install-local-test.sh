#!/bin/bash
# Tests for scripts/install-local.sh, the step behind `make install` / `make install-signed` (#239).
#
# The install step must copy a product it built in the same run, taken from
# `swift build --show-bin-path` (not the shared .build/release path), and must check it with
# check_staged_product (exactly the host architecture, `--version` equal to AppVersion.current)
# before it touches the install directory. `swift` is replaced by a stub (SWIFT=...) that
# reports a fixture directory as the bin path, so each case runs in seconds and never
# replaces the maintainer's installed binary (INSTALL_DIR points into a temp dir).
# Run: bash scripts/tests/install-local-test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
INSTALL_SCRIPT="$PROJECT_DIR/scripts/install-local.sh"
VERSION=$(grep -E 'static let current = "' "$PROJECT_DIR/Sources/CheICalMCP/Version.swift" | sed -E 's/.*"([^"]+)".*/\1/')
[ -n "$VERSION" ] || { echo "cannot read AppVersion.current"; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/install-local-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
HOST=$(uname -m)
OTHER=$([ "$HOST" = arm64 ] && echo x86_64 || echo arm64)

ok()  { echo "✓ $1"; PASS=$((PASS+1)); }
bad() { echo "✗ $1"; FAIL=$((FAIL+1)); }

# fixture <dir> <arch> <stdout first line> — a CheICalMCP stand-in in <dir>.
fixture() {
    mkdir -p "$1"
    printf '#include <stdio.h>\nint main(void){puts("%s");return 0;}\n' "$3" > "$TMP/fx.c"
    clang -arch "$2" -o "$1/CheICalMCP" "$TMP/fx.c" 2>/dev/null || { echo "cannot build fixture for $2"; exit 2; }
}

# A swift stub: `build ... --show-bin-path` prints $FAKE_BIN_DIR; any other `build` records
# its arguments and succeeds without building.
mkdir -p "$TMP/stub"
cat > "$TMP/stub/swift" <<'EOF'
#!/bin/bash
for a in "$@"; do [ "$a" = --show-bin-path ] && { echo "$FAKE_BIN_DIR"; exit 0; }; done
echo "$*" >> "$SWIFT_CALLS"
exit 0
EOF
chmod +x "$TMP/stub/swift"

# run_install <bin dir> <install dir> — runs the install step with the stub; prints its output.
run_install() {
    FAKE_BIN_DIR="$1" SWIFT_CALLS="$TMP/calls" SWIFT="$TMP/stub/swift" INSTALL_DIR="$2" \
        bash "$INSTALL_SCRIPT" adhoc 2>&1
}

[ -f "$INSTALL_SCRIPT" ] || { bad "scripts/install-local.sh exists"; echo; echo "$PASS passed, $FAIL failed"; exit 1; }

# 1. A host-arch product of the source version is installed, from the reported bin path.
fixture "$TMP/good" "$HOST" "CheICalMCP $VERSION"
rm -f "$TMP/calls"
out=$(run_install "$TMP/good" "$TMP/dest1") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -x "$TMP/dest1/CheICalMCP" ]; then ok "a checked host-arch product is installed"
else bad "a checked host-arch product is installed — rc=$rc: $out"; fi
archs=$(lipo -archs "$TMP/dest1/CheICalMCP" 2>&1)
[ "$archs" = "$HOST" ] && ok "the installed file holds exactly $HOST" || bad "the installed file holds exactly $HOST — got '$archs'"
first=$("$TMP/dest1/CheICalMCP" --version 2>/dev/null | head -1)
[ "$first" = "CheICalMCP $VERSION" ] && ok "the installed file reports the source version" || bad "the installed file reports the source version — got '$first'"
if grep -q -- "--arch $HOST" "$TMP/calls" 2>/dev/null; then ok "the build is run for the host architecture"
else bad "the build is run for the host architecture — calls: $(cat "$TMP/calls" 2>/dev/null)"; fi
codesign -v "$TMP/dest1/CheICalMCP" 2>/dev/null && ok "the installed file is signed" || bad "the installed file is signed"

# 2-3. A wrong product is refused before the install directory is touched.
refused() {   # refused <desc> <bin dir> <needle>
    mkdir -p "$TMP/dest-$1"
    echo "previous install" > "$TMP/dest-$1/CheICalMCP"
    out=$(run_install "$2" "$TMP/dest-$1") && rc=0 || rc=$?
    if [ $rc -ne 0 ] && [[ "$out" == *"$3"* ]]; then ok "$1 is refused"
    else bad "$1 is refused — rc=$rc: $out"; fi
    [ "$(cat "$TMP/dest-$1/CheICalMCP" 2>/dev/null)" = "previous install" ] \
        && ok "$1 leaves the installed file untouched" || bad "$1 leaves the installed file untouched"
}
fixture "$TMP/other" "$OTHER" "CheICalMCP $VERSION"
refused "a product of another architecture" "$TMP/other" "expected '$HOST'"
fixture "$TMP/older" "$HOST" "CheICalMCP 0.0.1"
refused "a product reporting another version" "$TMP/older" "reports 'CheICalMCP 0.0.1'"
refused "a missing product" "$TMP/empty-bin" "no $HOST product"

# 4. The fixed shared path is no longer copied.
if grep -q '\.build/release' "$PROJECT_DIR/Makefile"; then bad "the Makefile no longer copies .build/release"
else ok "the Makefile no longer copies .build/release"; fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
