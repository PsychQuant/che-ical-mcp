#!/bin/bash
# Tests for scripts/install-local.sh, the step behind `make install` / `make install-signed` (#239).
#
# The install step must copy a product it built in the same run, taken from
# `swift build --show-bin-path` (not the shared .build/release path), check it with
# check_staged_product (exactly the host architecture, `--version` equal to AppVersion.current),
# sign and verify the staged copy, and only then touch the install directory. `swift` and the
# signing `codesign` are replaced by stubs (CHE_ICAL_SWIFT / CHE_ICAL_CODESIGN), so each case
# runs in seconds and never replaces the maintainer's installed binary (the install directory
# is a temp dir).
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
# A codesign stub that fails, and one that succeeds without signing anything.
printf '#!/bin/sh\necho "stub: signing refused" >&2\nexit 1\n' > "$TMP/stub/codesign-fails"
printf '#!/bin/sh\nexit 0\n' > "$TMP/stub/codesign-noop"
for f in swift codesign-fails codesign-noop; do /bin/chmod u+x "$TMP/stub/$f"; done

# run_install <mode> <bin dir> <install dir> [env...] — runs the install step with the swift
# stub; prints its output.
run_install() {
    local mode="$1" bin="$2" dir="$3"; shift 3
    env FAKE_BIN_DIR="$bin" SWIFT_CALLS="$TMP/calls" CHE_ICAL_SWIFT="$TMP/stub/swift" "$@" \
        bash "$INSTALL_SCRIPT" "$mode" "$dir" 2>&1
}

[ -f "$INSTALL_SCRIPT" ] || { bad "scripts/install-local.sh exists"; echo; echo "$PASS passed, $FAIL failed"; exit 1; }

# 1. A host-arch product of the source version is installed, from the reported bin path.
fixture "$TMP/good" "$HOST" "CheICalMCP $VERSION"
rm -f "$TMP/calls"
out=$(run_install adhoc "$TMP/good" "$TMP/dest1") && rc=0 || rc=$?
if [ $rc -eq 0 ] && [ -x "$TMP/dest1/CheICalMCP" ]; then ok "a checked host-arch product is installed"
else bad "a checked host-arch product is installed — rc=$rc: $out"; fi
[[ "$out" == *"to $TMP/dest1/CheICalMCP"* ]] && ok "the destination is printed before installing" \
    || bad "the destination is printed before installing — $out"
archs=$(lipo -archs "$TMP/dest1/CheICalMCP" 2>&1)
[ "$archs" = "$HOST" ] && ok "the installed file holds exactly $HOST" || bad "the installed file holds exactly $HOST — got '$archs'"
first=$("$TMP/dest1/CheICalMCP" --version 2>/dev/null | head -1)
[ "$first" = "CheICalMCP $VERSION" ] && ok "the installed file reports the source version" || bad "the installed file reports the source version — got '$first'"
if grep -q -- "--arch $HOST" "$TMP/calls" 2>/dev/null; then ok "the build is run for the host architecture"
else bad "the build is run for the host architecture — calls: $(cat "$TMP/calls" 2>/dev/null)"; fi
codesign --verify --strict "$TMP/dest1/CheICalMCP" 2>/dev/null && ok "the installed file verifies strictly" || bad "the installed file verifies strictly"
# clang's own signature is "linker-signed"; only `codesign --sign -` replaces it.
sig=$(codesign -dv "$TMP/dest1/CheICalMCP" 2>&1)
if [[ "$sig" == *"Signature=adhoc"* && "$sig" != *"linker-signed"* ]]; then ok "the installed file was signed by codesign"
else bad "the installed file was signed by codesign — $sig"; fi

# 2-4. A wrong product is refused before the install directory is touched.
refused() {   # refused <desc> <mode> <bin dir> <needle> [env...]
    local desc="$1" mode="$2" bin="$3" needle="$4"; shift 4
    local dir="$TMP/dest-${desc// /-}"
    mkdir -p "$dir"
    echo "previous install" > "$dir/CheICalMCP"
    out=$(run_install "$mode" "$bin" "$dir" "$@") && rc=0 || rc=$?
    if [ $rc -ne 0 ] && [[ "$out" == *"$needle"* ]]; then ok "$desc is refused"
    else bad "$desc is refused — rc=$rc: $out"; fi
    [ "$(cat "$dir/CheICalMCP" 2>/dev/null)" = "previous install" ] \
        && ok "$desc leaves the installed file untouched" || bad "$desc leaves the installed file untouched"
}
fixture "$TMP/other" "$OTHER" "CheICalMCP $VERSION"
refused "a product of another architecture" adhoc "$TMP/other" "expected '$HOST'"
fixture "$TMP/older" "$HOST" "CheICalMCP 0.0.1"
refused "a product reporting another version" adhoc "$TMP/older" "reports 'CheICalMCP 0.0.1'"
refused "a missing product" adhoc "$TMP/empty-bin" "no $HOST product"

# 5-6. Signing happens on the staged copy: a failed or skipped signature installs nothing.
refused "a failed ad-hoc signature" adhoc "$TMP/good" "signing failed" CHE_ICAL_CODESIGN="$TMP/stub/codesign-fails"
refused "a signature codesign did not make" adhoc "$TMP/good" "not ad-hoc signed" CHE_ICAL_CODESIGN="$TMP/stub/codesign-noop"

# 6b. The final replace is atomic: a copy into the install directory that fails leaves the old
# install in place (the copy goes to a temp file there, which is then renamed over it).
mkdir -p "$TMP/cpstub"
cat > "$TMP/cpstub/cp" <<'EOF2'
#!/bin/bash
last="${@: -1}"
case "$last" in "$FAIL_CP_UNDER"/*) echo "stub: cp refused" >&2; exit 1 ;; esac
exec /bin/cp "$@"
EOF2
/bin/chmod u+x "$TMP/cpstub/cp"
refused "a copy into the install directory that fails" adhoc "$TMP/good" "cannot copy the checked product" \
    PATH="$TMP/cpstub:$PATH" FAIL_CP_UNDER="$TMP/dest-a-copy-into-the-install-directory-that-fails"
left=$(ls -A "$TMP/dest-a-copy-into-the-install-directory-that-fails")
[ "$left" = CheICalMCP ] && ok "a failed copy leaves no temp file behind" || bad "a failed copy leaves no temp file behind — left: $left"
# The replaced file is a new inode (#62) and stays executable.
ino_before=$(stat -f %i "$TMP/dest1/CheICalMCP")
out=$(run_install adhoc "$TMP/good" "$TMP/dest1") && rc=0 || rc=$?
ino_after=$(stat -f %i "$TMP/dest1/CheICalMCP")
[ $rc -eq 0 ] && [ "$ino_before" != "$ino_after" ] && [ -x "$TMP/dest1/CheICalMCP" ] \
    && ok "a reinstall replaces the file with a new, executable inode" \
    || bad "a reinstall replaces the file with a new, executable inode — rc=$rc inode $ino_before -> $ino_after: $out"
[ "$(ls -A "$TMP/dest1")" = CheICalMCP ] && ok "a reinstall leaves no temp file behind" || bad "a reinstall leaves no temp file behind — $(ls -A "$TMP/dest1")"

# 6c. The installed path must be a file: a directory, or a symlink to one, is refused before
# anything is copied, and neither is changed (#239 verify round 3).
mkdir -p "$TMP/dest-dir/CheICalMCP"
echo keep > "$TMP/dest-dir/CheICalMCP/inside"
out=$(run_install adhoc "$TMP/good" "$TMP/dest-dir") && rc=0 || rc=$?
if [ $rc -ne 0 ] && [[ "$out" == *"is a directory"* ]]; then ok "an installed path that is a directory is refused"
else bad "an installed path that is a directory is refused — rc=$rc: $out"; fi
[ "$(ls -A "$TMP/dest-dir/CheICalMCP")" = inside ] && ok "the directory is left as it was" \
    || bad "the directory is left as it was — $(ls -A "$TMP/dest-dir/CheICalMCP")"
mkdir -p "$TMP/dest-link" "$TMP/link-target"
echo keep > "$TMP/link-target/inside"
ln -s "$TMP/link-target" "$TMP/dest-link/CheICalMCP"
out=$(run_install adhoc "$TMP/good" "$TMP/dest-link") && rc=0 || rc=$?
if [ $rc -ne 0 ] && [[ "$out" == *"is a directory"* ]]; then ok "an installed path that is a symlink to a directory is refused"
else bad "an installed path that is a symlink to a directory is refused — rc=$rc: $out"; fi
[ -L "$TMP/dest-link/CheICalMCP" ] && [ "$(ls -A "$TMP/link-target")" = inside ] \
    && ok "the symlink and its target are left as they were" \
    || bad "the symlink and its target are left as they were — $(ls -la "$TMP/dest-link" "$TMP/link-target")"

# 6d. The signature checks read whole lines of `codesign -dv`, not substrings: a stage path that
# contains "linker-signed" must not make a good ad-hoc signature look linker-signed.
mkdir -p "$TMP/linker-signed-tmp"
out=$(run_install adhoc "$TMP/good" "$TMP/dest-anchored" TMPDIR="$TMP/linker-signed-tmp") && rc=0 || rc=$?
[ $rc -eq 0 ] && [ -x "$TMP/dest-anchored/CheICalMCP" ] && ok "a stage path containing linker-signed does not refuse a good signature" \
    || bad "a stage path containing linker-signed does not refuse a good signature — rc=$rc: $out"

# 7. developer-id: an identity that is not in the keychain stops before anything is built.
rm -f "$TMP/calls"
refused "a Developer ID that is not in the keychain" developer-id "$TMP/good" "cannot sign with Developer ID" \
    DEVELOPER_ID="Developer ID Application: Nobody (ZZZZZZZZZZ)"
[ ! -f "$TMP/calls" ] && ok "a missing identity stops before the build" || bad "a missing identity stops before the build — calls: $(cat "$TMP/calls")"
refused "developer-id without DEVELOPER_ID" developer-id "$TMP/good" "DEVELOPER_ID not set" DEVELOPER_ID=

# 8. developer-id with a real identity (only where one is in the keychain): a failed signature
# and a signature without that identity's team install nothing.
REAL_ID=$(security find-identity -p codesigning -v 2>/dev/null | sed -nE 's/.*"(Developer ID Application: [^"]+)".*/\1/p' | head -1)
if [ -n "$REAL_ID" ]; then
    refused "a failed Developer ID signature" developer-id "$TMP/good" "Developer ID signing failed" \
        DEVELOPER_ID="$REAL_ID" CHE_ICAL_CODESIGN="$TMP/stub/codesign-fails"
    refused "a signature without the identity's team" developer-id "$TMP/good" "TeamIdentifier" \
        DEVELOPER_ID="$REAL_ID" CHE_ICAL_CODESIGN="$TMP/stub/codesign-noop"
    # The stage path names the team: a substring check would read it from the Executable= line.
    REAL_TEAM=$(printf '%s' "$REAL_ID" | sed -nE 's/.*\(([A-Z0-9]{10})\)$/\1/p')
    mkdir -p "$TMP/TeamIdentifier=$REAL_TEAM"
    refused "an unsigned product whose path names the team" developer-id "$TMP/good" "TeamIdentifier" \
        DEVELOPER_ID="$REAL_ID" CHE_ICAL_CODESIGN="$TMP/stub/codesign-noop" TMPDIR="$TMP/TeamIdentifier=$REAL_TEAM"
else
    echo "- skipped: no Developer ID Application identity in this keychain (developer-id signing cases)"
fi

# 9. The install directory is an argument; a relative one is read against the caller's cwd.
mkdir -p "$TMP/cwd"
out=$(cd "$TMP/cwd" && run_install adhoc "$TMP/good" rel/bin) && rc=0 || rc=$?
[ $rc -eq 0 ] && [ -x "$TMP/cwd/rel/bin/CheICalMCP" ] && ok "a relative install dir is read against the caller's directory" \
    || bad "a relative install dir is read against the caller's directory — rc=$rc: $out"

# 10. An unreadable AppVersion.current is reported, not a silent exit.
mkdir -p "$TMP/tree/scripts/lib" "$TMP/tree/Sources/CheICalMCP"
cp "$INSTALL_SCRIPT" "$TMP/tree/scripts/"
cp "$PROJECT_DIR/scripts/lib/check-staged-product.sh" "$TMP/tree/scripts/lib/"
echo "enum AppVersion {}" > "$TMP/tree/Sources/CheICalMCP/Version.swift"
out=$(bash "$TMP/tree/scripts/install-local.sh" adhoc "$TMP/dest-tree" 2>&1) && rc=0 || rc=$?
[ $rc -ne 0 ] && [[ "$out" == *"cannot read AppVersion.current"* ]] && ok "an unreadable version is reported" \
    || bad "an unreadable version is reported — rc=$rc: $out"

# 11. The Makefile: no recipe copies the shared path, and an exported INSTALL_DIR does not
# redirect `make install` while `make install INSTALL_DIR=...` does.
if grep -E $'^\t.*cp .*\\.build/release' "$PROJECT_DIR/Makefile" >/dev/null; then bad "no Makefile recipe copies .build/release"
else ok "no Makefile recipe copies .build/release"; fi
dry=$(cd "$PROJECT_DIR" && INSTALL_DIR=/should/not/be/used make -n install FALLBACK_FLAGS= 2>/dev/null)
[[ "$dry" != *"/should/not/be/used"* && "$dry" == *"$HOME/bin"* ]] && ok "an exported INSTALL_DIR does not redirect make install" \
    || bad "an exported INSTALL_DIR does not redirect make install — $dry"
dry=$(cd "$PROJECT_DIR" && make -n install INSTALL_DIR=/explicit/dir FALLBACK_FLAGS= 2>/dev/null)
[[ "$dry" == *"/explicit/dir"* ]] && ok "make install INSTALL_DIR=... chooses the directory" \
    || bad "make install INSTALL_DIR=... chooses the directory — $dry"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
