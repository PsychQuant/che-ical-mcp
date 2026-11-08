#!/bin/bash
# Tests for plugin/bin/che-ical-mcp-wrapper.sh, the plugin's auto-download wrapper (#483).
#
# The sidecar ~/bin/.CheICalMCP.version must record the release actually installed, not the
# version plugin.json pins: after a fallback to releases/latest it holds the latest tag (or
# `unknown`), so the pinned release is fetched once it exists. A sidecar that disagrees with
# the binary's own `--version` must not stop the download.
#
# Hermetic: HOME is a temp dir (the wrapper installs to $HOME/bin), `curl` is a stub first on
# PATH that serves canned release JSON and writes a fake CheICalMCP (a shell script that
# answers `--version`), and the wrapper runs from a temp plugin root with its own plugin.json.
# Nothing touches the network, the real ~/bin or any calendar.
# Run: bash scripts/tests/plugin-wrapper-test.sh
# WRAPPER_UNDER_TEST=<path> runs the same cases against another copy (e.g. the pre-#483 one).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
WRAPPER="${WRAPPER_UNDER_TEST:-$PROJECT_DIR/plugin/bin/che-ical-mcp-wrapper.sh}"
[ -f "$WRAPPER" ] || { echo "wrapper not found: $WRAPPER"; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/plugin-wrapper-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok()  { echo "✓ $1"; PASS=$((PASS+1)); }
bad() { echo "✗ $1"; FAIL=$((FAIL+1)); }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
has()   { if grep -qF -- "$3" "$2"; then ok "$1"; else bad "$1 (no '$3' in $(basename "$2"))"; fi; }
hasnt() { if grep -qF -- "$3" "$2"; then bad "$1 ('$3' found in $(basename "$2"))"; else ok "$1"; fi; }

REPO_PATH="PsychQuant/che-ical-mcp"

# fake_binary <path> <version> — a CheICalMCP stand-in: `--version` prints the real format,
# anything else prints `RAN <version>` (the wrapper's final exec lands here).
fake_binary() {
    printf '#!/bin/bash\nif [ "${1:-}" = --version ]; then echo "CheICalMCP %s"; exit 0; fi\necho "RAN %s"\n' "$2" "$2" > "$1"
    /bin/chmod u+x "$1"
}

# The curl stub. API URLs are answered from $RELEASES/<tag-vX.Y.Z|latest>.json (a missing file
# answers GitHub's Not Found body); a releases/download URL with -o writes a fake binary of
# that version, or fails when $DOWNLOAD_FAIL is set. Every call is logged; any other URL fails.
mkdir -p "$TMP/stub"
cat > "$TMP/stub/curl" <<'EOF'
#!/bin/bash
url="" out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        http*) url="$1" ;;
    esac
    shift
done
echo "$url" >> "$CURL_LOG"
case "$url" in
    https://api.github.com/repos/PsychQuant/che-ical-mcp/releases/tags/*)
        f="$RELEASES/tag-${url##*/}.json" ;;
    https://api.github.com/repos/PsychQuant/che-ical-mcp/releases/latest)
        f="$RELEASES/latest.json" ;;
    https://github.com/PsychQuant/che-ical-mcp/releases/download/*/CheICalMCP)
        [ -n "${DOWNLOAD_FAIL:-}" ] && exit 22
        [ -n "$out" ] || exit 2
        v="${url%/CheICalMCP}"; v="${v##*/v}"
        printf '#!/bin/bash\nif [ "${1:-}" = --version ]; then echo "CheICalMCP %s"; exit 0; fi\necho "RAN %s"\n' "$v" "$v" > "$out"
        exit 0 ;;
    *) echo "UNEXPECTED $url" >> "$CURL_LOG"; exit 99 ;;
esac
if [ -f "$f" ]; then cat "$f"; else printf '{\n  "message": "Not Found",\n  "status": "404"\n}\n'; fi
EOF
/bin/chmod u+x "$TMP/stub/curl"

# release_json <file> <version> [no-tag] — a pretty-printed release body like the GitHub API's,
# with the binary and its .sha256 as assets.
release_json() {
    local tag_line="  \"tag_name\": \"v$2\","
    [ "${3:-}" = no-tag ] && tag_line="  \"name\": \"release\","
    cat > "$1" <<EOF
{
  "url": "https://api.github.com/repos/$REPO_PATH/releases/1",
$tag_line
  "assets": [
    {
      "name": "CheICalMCP.sha256",
      "browser_download_url": "https://github.com/$REPO_PATH/releases/download/v$2/CheICalMCP.sha256"
    },
    {
      "name": "CheICalMCP",
      "browser_download_url": "https://github.com/$REPO_PATH/releases/download/v$2/CheICalMCP"
    }
  ]
}
EOF
}

# setup <name> <pinned version> — a fresh HOME, plugin root and release set for one case.
setup() {
    C="$TMP/$1"
    mkdir -p "$C/home" "$C/releases" "$C/plugin/bin" "$C/plugin/.claude-plugin"
    cp "$WRAPPER" "$C/plugin/bin/che-ical-mcp-wrapper.sh"
    printf '{\n  "name": "che-ical-mcp",\n  "version": "%s",\n  "license": "MIT"\n}\n' "$2" \
        > "$C/plugin/.claude-plugin/plugin.json"
    BIN="$C/home/bin/CheICalMCP"
    SIDE="$C/home/bin/.CheICalMCP.version"
    : > "$C/curl.log"
}
install_existing() { mkdir -p "$C/home/bin"; fake_binary "$BIN" "$1"; echo "$2" > "$SIDE"; }
run_wrapper() {
    HOME="$C/home" PATH="$TMP/stub:$PATH" CURL_LOG="$C/curl.log" RELEASES="$C/releases" \
        bash "$C/plugin/bin/che-ical-mcp-wrapper.sh" mcp-arg > "$C/out" 2> "$C/err"
    RC=$?
}
bin_version() { "$BIN" --version 2>/dev/null | awk '{print $NF}'; }
side() { tr -d '[:space:]' < "$SIDE" 2>/dev/null; }

# 1. The #483 repro: pinned tag unreleased, fallback to latest.
setup fallback 1.23.0
release_json "$C/releases/latest.json" 1.22.0
run_wrapper
check "fallback: wrapper ran the installed binary" "$(cat "$C/out")" "RAN 1.22.0"
check "fallback: binary is the latest release" "$(bin_version)" "1.22.0"
check "fallback: sidecar records the release fetched, not the pin" "$(side)" "1.22.0"
has "fallback: says the pin has no release" "$C/err" "v1.23.0 has no release"
[ -e "$BIN.tmp" ] && bad "fallback: no .tmp left behind" || ok "fallback: no .tmp left behind"

# 2. Same machine after the pinned release is published: the next spawn fetches it.
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
release_json "$C/releases/latest.json" 1.23.0
: > "$C/curl.log"
run_wrapper
check "after release: binary is the pinned release" "$(bin_version)" "1.23.0"
check "after release: sidecar is the pinned release" "$(side)" "1.23.0"
check "after release: wrapper ran the new binary" "$(cat "$C/out")" "RAN 1.23.0"
has "after release: downloaded the pinned asset" "$C/curl.log" "/releases/download/v1.23.0/CheICalMCP"

# 3. A machine left by the old wrapper: sidecar says the pin, binary is older, pin released.
setup repair 1.23.0
install_existing 1.22.0 1.23.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
run_wrapper
check "repair: stale binary replaced" "$(bin_version)" "1.23.0"
check "repair: sidecar matches binary" "$(side)" "1.23.0"
has "repair: reason names the disagreement" "$C/err" "binary reports v1.22.0"
hasnt "repair: latest not consulted when the pin answers" "$C/curl.log" "releases/latest"

# 4. During the gap, latest is already installed: no binary download, sidecar stays truthful.
setup gap 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/latest.json" 1.22.0
run_wrapper
check "gap: binary unchanged" "$(bin_version)" "1.22.0"
check "gap: sidecar records what is installed" "$(side)" "1.22.0"
hasnt "gap: no binary download" "$C/curl.log" "/releases/download/"
has "gap: warns the pin is unreleased" "$C/err" "v1.23.0 has no release yet"
check "gap: wrapper ran the binary" "$(cat "$C/out")" "RAN 1.22.0"

# 5. Old wrong sidecar during the gap: corrected without a download.
setup gap-wrong-sidecar 1.23.0
install_existing 1.22.0 1.23.0
release_json "$C/releases/latest.json" 1.22.0
run_wrapper
check "gap+wrong sidecar: sidecar corrected" "$(side)" "1.22.0"
hasnt "gap+wrong sidecar: no binary download" "$C/curl.log" "/releases/download/"

# 6. Up to date: sidecar, binary and pin agree → no network at all.
setup current 1.23.0
install_existing 1.23.0 1.23.0
run_wrapper
check "current: curl never called" "$(wc -l < "$C/curl.log" | tr -d ' ')" "0"
check "current: wrapper ran the binary" "$(cat "$C/out")" "RAN 1.23.0"
check "current: exit status of the binary" "$RC" "0"

# 7. Fallback release without a readable tag → `unknown`, and the next run checks again.
setup no-tag 1.23.0
release_json "$C/releases/latest.json" 1.22.0 no-tag
run_wrapper
check "no tag: sidecar is unknown" "$(side)" "unknown"
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
: > "$C/curl.log"
run_wrapper
check "no tag: next run fetches the pin" "$(bin_version)" "1.23.0"
check "no tag: next run records it" "$(side)" "1.23.0"

# 8. Pinned release body without tag_name: the pin is what was fetched.
setup pinned-no-tag 1.23.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0 no-tag
run_wrapper
check "pinned, no tag: sidecar is the pin" "$(side)" "1.23.0"
hasnt "pinned, no tag: no fallback warning" "$C/err" "has no release"

# 9. Download fails with a binary present: keep it, sidecar untouched, no .tmp.
setup download-fails 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
HOME="$C/home" PATH="$TMP/stub:$PATH" CURL_LOG="$C/curl.log" RELEASES="$C/releases" DOWNLOAD_FAIL=1 \
    bash "$C/plugin/bin/che-ical-mcp-wrapper.sh" > "$C/out" 2> "$C/err"
check "download fails: binary kept" "$(bin_version)" "1.22.0"
check "download fails: sidecar untouched" "$(side)" "1.22.0"
has "download fails: warning" "$C/err" "download failed, keeping existing binary"
[ -e "$BIN.tmp" ] && bad "download fails: .tmp removed" || ok "download fails: .tmp removed"
check "download fails: still runs the binary" "$(cat "$C/out")" "RAN 1.22.0"

# 10. Download fails with no binary: exit 1.
setup download-fails-fresh 1.23.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
HOME="$C/home" PATH="$TMP/stub:$PATH" CURL_LOG="$C/curl.log" RELEASES="$C/releases" DOWNLOAD_FAIL=1 \
    bash "$C/plugin/bin/che-ical-mcp-wrapper.sh" > "$C/out" 2> "$C/err"
check "download fails, fresh: exit 1" "$?" "1"
has "download fails, fresh: error" "$C/err" "ERROR — download failed"

# 11. No release anywhere: keep an existing binary; without one, exit 1.
setup no-url 1.23.0
install_existing 1.22.0 1.22.0
run_wrapper
has "no url: warning" "$C/err" "no download URL found, keeping existing binary"
check "no url: sidecar untouched" "$(side)" "1.22.0"
setup no-url-fresh 1.23.0
run_wrapper
check "no url, fresh: exit 1" "$RC" "1"
has "no url, fresh: error" "$C/err" "ERROR — no download URL found"

# 12. Sidecar matches the pin but the binary cannot answer --version: download.
setup unreadable 1.23.0
mkdir -p "$C/home/bin"
printf '#!/bin/bash\nexit 3\n' > "$BIN"; /bin/chmod u+x "$BIN"
echo 1.23.0 > "$SIDE"
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
run_wrapper
check "unreadable --version: replaced" "$(bin_version)" "1.23.0"

# 13. Sidecar missing, binary already at the pin: record it without downloading.
setup sidecar-missing 1.23.0
mkdir -p "$C/home/bin"; fake_binary "$BIN" 1.23.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
run_wrapper
check "sidecar missing: recorded" "$(side)" "1.23.0"
hasnt "sidecar missing: no binary download" "$C/curl.log" "/releases/download/"

# 14. plugin.json unreadable, binary present: no download (unchanged behavior).
setup no-pin 1.23.0
rm "$C/plugin/.claude-plugin/plugin.json"
install_existing 1.22.0 1.22.0
run_wrapper
check "no pin: curl never called" "$(wc -l < "$C/curl.log" | tr -d ' ')" "0"

hasnt "no case reached an unexpected URL" <(cat "$TMP"/*/curl.log) "UNEXPECTED"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
