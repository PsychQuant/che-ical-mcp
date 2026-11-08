#!/bin/bash
# Tests for plugin/bin/che-ical-mcp-wrapper.sh, the plugin's auto-download wrapper (#483).
#
# What the wrapper must do:
# - Decide from what the binary reports (`CheICalMCP --version`), not from the sidecar: download
#   when the binary is missing, cannot report a version, or reports one OLDER than the version
#   plugin.json pins; never replace a binary newer than the pin (--self-update, make install).
# - The sidecar ~/bin/.CheICalMCP.version records what the installed binary reports, never the
#   pin it wanted. After a fallback to releases/latest it holds what latest shipped, so the
#   pinned release is fetched once it exists.
# - Not download a release again while ~/bin/.CheICalMCP.release says what it ships and the
#   installed binary is no worse: it reports a version not older than what the release's asset
#   reported, or the release's asset reported none and the installed file is that asset (same
#   cksum) or the version kept over it. A failed download writes no record and is retried on
#   the next spawn; deleting the record also makes the wrapper retry.
# - Never replace a binary with an asset that is not newer than what is installed at the moment
#   of the mv (the binary is probed again after the download).
# - Download in one spawn at a time (lock ~/bin/.CheICalMCP.lock); a lock whose pid is dead is
#   taken at once; a TERM during the download ends the wrapper promptly and leaves no lock or
#   temp file; leftover temp files of killed runs are removed.
# - Leave stdin alone (`--version` probes read /dev/null): stdin is the MCP channel.
#
# Hermetic: HOME is a temp dir (the wrapper installs to $HOME/bin), `curl` is a stub first on
# PATH that serves canned release JSON and writes a fake CheICalMCP (a shell script that answers
# `--version`), and the wrapper runs from a temp plugin root with its own plugin.json. Nothing
# touches the network, the real ~/bin or any calendar.
# The wrapper always runs under /bin/bash (its shebang interpreter, bash 3.2 on macOS), not
# whatever bash is first on PATH.
# Run: bash scripts/tests/plugin-wrapper-test.sh
# WRAPPER_UNDER_TEST=<path> runs the same cases against another copy (e.g. an older one).
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
count() { grep -cF -- "$2" "$1" 2>/dev/null | tr -d ' '; }

REPO_PATH="PsychQuant/che-ical-mcp"
mkdir -p "$TMP/stub"

# mkfake <path> <--version output> — a CheICalMCP stand-in. `--version` prints the given line
# and swallows a line of stdin if one is there (a probe that does not read /dev/null eats the
# MCP request); anything else prints `RAN <output> <first stdin line>`, which is where the
# wrapper's final exec lands. Shared by the tests and the curl stub.
cat > "$TMP/stub/mkfake" <<'EOF'
#!/bin/bash
cat > "$1" <<FAKE
#!/bin/bash
if [ "\${1:-}" = --version ]; then read -r -t 1 _ 2>/dev/null; echo "$2"; exit 0; fi
read -r line
echo "RAN $2 \$line"
FAKE
/bin/chmod u+x "$1"
EOF
/bin/chmod u+x "$TMP/stub/mkfake"
fake_binary() { "$TMP/stub/mkfake" "$1" "CheICalMCP $2"; }

# The curl stub. API URLs are answered from $RELEASES/<tag-vX.Y.Z|latest>.json (a missing file
# answers GitHub's Not Found body). A releases/download/<tag>/CheICalMCP URL with -o writes a
# fake binary whose --version prints `CheICalMCP <tag version>`, or the content of
# $RELEASES/asset-<tag>.version when present. $RELEASES/asset-<tag>.http-error makes the asset
# answer an HTTP error: with -f curl writes nothing and exits 22, without -f it writes the error
# body and exits 0 (real curl behavior). $DOWNLOAD_FAIL fails every download. Every call is
# logged; any other URL fails.
cat > "$TMP/stub/curl" <<'EOF'
#!/bin/bash
url="" out="" fail_flag=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        --max-time) max_time="$2"; shift ;;
        http*) url="$1" ;;
        -*) case "$1" in -*f*) [ "${1#--}" = "$1" ] && fail_flag=1 ;; esac
            [ "$1" = --fail ] && fail_flag=1 ;;
    esac
    shift
done
echo "$url" >> "$CURL_LOG"
echo "${max_time:-none} $url" >> "$CURL_LOG.max-time"
case "$url" in
    https://api.github.com/repos/PsychQuant/che-ical-mcp/releases/tags/*)
        f="$RELEASES/tag-${url##*/}.json" ;;
    https://api.github.com/repos/PsychQuant/che-ical-mcp/releases/latest)
        f="$RELEASES/latest.json" ;;
    https://github.com/PsychQuant/che-ical-mcp/releases/download/*/CheICalMCP)
        [ -n "${DOWNLOAD_FAIL:-}" ] && exit 22
        [ -n "$out" ] || exit 2
        tag="${url%/CheICalMCP}"; tag="${tag##*/}"
        if [ -f "$RELEASES/asset-$tag.http-error" ]; then
            [ -n "$fail_flag" ] && exit 22
            printf 'Not Found\n' > "$out"; exit 0
        fi
        report="CheICalMCP ${tag#v}"
        [ -f "$RELEASES/asset-$tag.version" ] && report=$(cat "$RELEASES/asset-$tag.version")
        if [ -n "${SLOW_ASSET:-}" ]; then
            # Two stages, like a real slow download: half the file, a pause, the rest.
            "$(dirname "$0")/mkfake" "$RELEASES/full.$$" "$report"
            size=$(wc -c < "$RELEASES/full.$$" | tr -d ' ')
            head -c $((size / 2)) "$RELEASES/full.$$" > "$out"
            sleep "$SLOW_ASSET"
            tail -c +$((size / 2 + 1)) "$RELEASES/full.$$" >> "$out"
            /bin/chmod u+x "$out"; rm -f "$RELEASES/full.$$"
            exit 0
        fi
        "$(dirname "$0")/mkfake" "$out" "$report"
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
install_existing() { mkdir -p "$C/home/bin"; fake_binary "$BIN" "$1"; [ -n "${2:-}" ] && echo "$2" > "$SIDE"; return 0; }
# run_wrapper [ENV=VALUE ...] — one spawn, with an MCP request line on stdin.
run_wrapper() {
    printf 'req\n' | env HOME="$C/home" PATH="$TMP/stub:$PATH" CURL_LOG="$C/curl.log" RELEASES="$C/releases" "$@" \
        /bin/bash "$C/plugin/bin/che-ical-mcp-wrapper.sh" mcp-arg > "$C/out" 2> "$C/err"
    RC=$?
}
# spawn_bg <tag> [ENV=VALUE ...] — one spawn in the background (output in $C/out.<tag>).
spawn_bg() {
    local tag="$1"; shift
    printf 'req\n' | env HOME="$C/home" PATH="$TMP/stub:$PATH" CURL_LOG="$C/curl.log" RELEASES="$C/releases" "$@" \
        /bin/bash "$C/plugin/bin/che-ical-mcp-wrapper.sh" mcp-arg > "$C/out.$tag" 2> "$C/err.$tag" &
}
release_record() { cat "$C/home/bin/.CheICalMCP.release" 2>/dev/null; }
# wait_download_started — until the stub has been asked for an asset (at most 5 s).
wait_download_started() {
    local i=0
    until grep -q "/releases/download/" "$C/curl.log" 2>/dev/null || (( i >= 50 )); do sleep 0.1; i=$((i + 1)); done
    sleep 0.2
}
# exits_within <pid> <seconds> → 0 when the process is gone within that time.
exits_within() {
    local i=0
    while kill -0 "$1" 2>/dev/null; do (( i >= $2 * 10 )) && return 1; sleep 0.1; i=$((i + 1)); done
    return 0
}
dead_pid() { /usr/bin/true & local p=$!; wait "$p"; echo "$p"; }
leftovers() { ls -A "$C/home/bin" | grep -vxE 'CheICalMCP|\.CheICalMCP\.version|\.CheICalMCP\.release' | tr '\n' ' '; }
bin_version() { "$BIN" --version </dev/null 2>/dev/null | awk '{print $NF}'; }
side() { tr -d '[:space:]' < "$SIDE" 2>/dev/null; }
downloads() { count "$C/curl.log" "/releases/download/"; }
calls() { wc -l < "$C/curl.log" | tr -d ' '; }

# 1. The #483 repro: pinned tag unreleased, fallback to latest.
setup fallback 1.23.0
release_json "$C/releases/latest.json" 1.22.0
run_wrapper
check "fallback: wrapper ran the installed binary, stdin intact" "$(cat "$C/out")" "RAN CheICalMCP 1.22.0 req"
check "fallback: binary is the latest release" "$(bin_version)" "1.22.0"
check "fallback: sidecar records the release fetched, not the pin" "$(side)" "1.22.0"
has "fallback: says the pin was not installed" "$C/err" "plugin wants v1.23.0"
check "fallback: no .tmp left behind" "$(leftovers)" ""

# 2. Same machine after the pinned release is published: the next spawn fetches it.
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
release_json "$C/releases/latest.json" 1.23.0
: > "$C/curl.log"
run_wrapper
check "after release: binary is the pinned release" "$(bin_version)" "1.23.0"
check "after release: sidecar is the pinned release" "$(side)" "1.23.0"
check "after release: wrapper ran the new binary" "$(cat "$C/out")" "RAN CheICalMCP 1.23.0 req"
has "after release: downloaded the pinned asset" "$C/curl.log" "/releases/download/v1.23.0/CheICalMCP"

# 3. A machine left by the first #483 wrapper: sidecar says the pin, binary is older, pin released.
setup repair 1.23.0
install_existing 1.22.0 1.23.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
run_wrapper
check "repair: stale binary replaced" "$(bin_version)" "1.23.0"
check "repair: sidecar matches binary" "$(side)" "1.23.0"
has "repair: reason names what the binary reports" "$C/err" "binary reports v1.22.0"
hasnt "repair: latest not consulted when the pin answers" "$C/curl.log" "releases/latest"

# 4. During the gap, latest is already installed: no download, at most two API calls.
setup gap 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/latest.json" 1.22.0
run_wrapper
check "gap: binary unchanged" "$(bin_version)" "1.22.0"
check "gap: sidecar records what is installed" "$(side)" "1.22.0"
check "gap: no binary download" "$(downloads)" "0"
check "gap: two API calls" "$(calls)" "2"
has "gap: warns the pin is unreleased" "$C/err" "v1.23.0 has no release yet"
check "gap: wrapper ran the binary" "$(cat "$C/out")" "RAN CheICalMCP 1.22.0 req"

# 5. Wrong sidecar during the gap: corrected without a download.
setup gap-wrong-sidecar 1.23.0
install_existing 1.22.0 1.23.0
release_json "$C/releases/latest.json" 1.22.0
run_wrapper
check "gap+wrong sidecar: sidecar corrected" "$(side)" "1.22.0"
check "gap+wrong sidecar: no binary download" "$(downloads)" "0"

# 6. Up to date: binary at the pin → no network at all.
setup current 1.23.0
install_existing 1.23.0 1.23.0
run_wrapper
check "current: curl never called" "$(calls)" "0"
check "current: wrapper ran the binary" "$(cat "$C/out")" "RAN CheICalMCP 1.23.0 req"
check "current: exit status of the binary" "$RC" "0"

# 7. Fallback release body without tag_name: the sidecar still records what was installed,
#    and the pinned release is fetched once it exists.
setup no-tag 1.23.0
release_json "$C/releases/latest.json" 1.22.0 no-tag
run_wrapper
check "no tag: sidecar is what the binary reports" "$(side)" "1.22.0"
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
: > "$C/curl.log"
run_wrapper
check "no tag: next run fetches the pin" "$(bin_version)" "1.23.0"
check "no tag: next run records it" "$(side)" "1.23.0"

# 8. Pinned release body without tag_name.
setup pinned-no-tag 1.23.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0 no-tag
run_wrapper
check "pinned, no tag: sidecar is the pin" "$(side)" "1.23.0"
hasnt "pinned, no tag: no warning" "$C/err" "WARNING"

# 9. Download fails with a binary present: keep it, sidecar untouched, no .tmp.
setup download-fails 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
run_wrapper DOWNLOAD_FAIL=1
check "download fails: binary kept" "$(bin_version)" "1.22.0"
check "download fails: sidecar untouched" "$(side)" "1.22.0"
has "download fails: warning" "$C/err" "download failed, keeping existing binary"
check "download fails: .tmp removed" "$(leftovers)" ""
check "download fails: still runs the binary" "$(cat "$C/out")" "RAN CheICalMCP 1.22.0 req"

# 10. Download fails with no binary: exit 1.
setup download-fails-fresh 1.23.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
run_wrapper DOWNLOAD_FAIL=1
check "download fails, fresh: exit 1" "$RC" "1"
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

# 12. The binary cannot answer --version: treated as missing, replaced.
setup unreadable 1.23.0
mkdir -p "$C/home/bin"
printf '#!/bin/bash\nexit 3\n' > "$BIN"; /bin/chmod u+x "$BIN"
echo 1.23.0 > "$SIDE"
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
run_wrapper
check "unreadable --version: replaced" "$(bin_version)" "1.23.0"

# 13. Sidecar missing, binary already at the pin: recorded with no network.
setup sidecar-missing 1.23.0
install_existing 1.23.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
run_wrapper
check "sidecar missing: recorded" "$(side)" "1.23.0"
check "sidecar missing: curl never called" "$(calls)" "0"

# 14. plugin.json unreadable, binary present: no download (unchanged behavior).
setup no-pin 1.23.0
rm "$C/plugin/.claude-plugin/plugin.json"
install_existing 1.22.0 1.22.0
run_wrapper
check "no pin: curl never called" "$(calls)" "0"

# 15. MEDIUM 1: the pinned release's asset reports another version than its tag.
#     Three spawns, one download; the sidecar holds what the binary reports.
setup asset-mismatch 1.23.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
echo "CheICalMCP 1.22.0" > "$C/releases/asset-v1.23.0.version"
run_wrapper; run_wrapper; run_wrapper
check "asset mismatch: one download over three spawns" "$(downloads)" "1"
check "asset mismatch: binary is what the release ships" "$(bin_version)" "1.22.0"
check "asset mismatch: sidecar is what the binary reports" "$(side)" "1.22.0"
has "asset mismatch: says what the release ships" "$C/err" "ships v1.22.0"
check "asset mismatch: still runs the binary" "$(cat "$C/out")" "RAN CheICalMCP 1.22.0 req"

# 16. Same, starting from an older installed binary.
setup asset-mismatch-upgrade 1.23.0
install_existing 1.21.0 1.21.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
echo "CheICalMCP 1.22.0" > "$C/releases/asset-v1.23.0.version"
run_wrapper; run_wrapper; run_wrapper
check "asset mismatch from 1.21.0: one download" "$(downloads)" "1"
check "asset mismatch from 1.21.0: binary is what the release ships" "$(bin_version)" "1.22.0"

# 17. The fallback release's asset reports another version than its tag (during the gap).
setup gap-asset-mismatch 1.23.0
install_existing 1.20.0 1.20.0
release_json "$C/releases/latest.json" 1.22.0
echo "CheICalMCP 1.21.0" > "$C/releases/asset-v1.22.0.version"
run_wrapper; run_wrapper; run_wrapper
check "gap asset mismatch: one download over three spawns" "$(downloads)" "1"
check "gap asset mismatch: sidecar is what the binary reports" "$(side)" "1.21.0"

# 18. The pinned asset does not report a version at all: the existing binary is kept, and the
#     same release is not downloaded again.
setup asset-unusable 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
echo "garbage" > "$C/releases/asset-v1.23.0.version"
run_wrapper; run_wrapper; run_wrapper
check "unusable asset: one download over three spawns" "$(downloads)" "1"
check "unusable asset: existing binary kept" "$(bin_version)" "1.22.0"
check "unusable asset: sidecar untouched" "$(side)" "1.22.0"
check "unusable asset: .tmp removed" "$(leftovers)" ""
has "unusable asset: warning" "$C/err" "does not report a version"

# 19. MEDIUM 2: a binary newer than the pin (--self-update, make install) is kept.
setup newer 1.23.0
install_existing 1.24.0 1.23.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
run_wrapper
check "newer: binary kept" "$(bin_version)" "1.24.0"
check "newer: curl never called" "$(calls)" "0"
check "newer: sidecar records what is installed" "$(side)" "1.24.0"
has "newer: says it is newer than the pin" "$C/err" "newer than the plugin pin"
check "newer: one stderr line" "$(wc -l < "$C/err" | tr -d ' ')" "1"
check "newer: runs the newer binary" "$(cat "$C/out")" "RAN CheICalMCP 1.24.0 req"

# 20. Numeric comparison: 1.10.0 is newer than 1.9.0.
setup newer-numeric 1.9.0
install_existing 1.10.0 1.10.0
release_json "$C/releases/tag-v1.9.0.json" 1.9.0
run_wrapper
check "numeric: 1.10.0 kept over pin 1.9.0" "$(bin_version)" "1.10.0"
check "numeric: curl never called" "$(calls)" "0"

# 21. Older than the pin (sidecar already agreeing with the binary): replaced.
setup older 1.23.0
install_existing 1.22.5 1.22.5
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
run_wrapper
check "older: replaced by the pin" "$(bin_version)" "1.23.0"
check "older: sidecar" "$(side)" "1.23.0"

# 22. Equal to the pin, sidecar disagreeing: kept, sidecar corrected, no network.
setup equal 1.23.0
install_existing 1.23.0 1.22.0
run_wrapper
check "equal: kept" "$(bin_version)" "1.23.0"
check "equal: curl never called" "$(calls)" "0"
check "equal: sidecar corrected" "$(side)" "1.23.0"

# 23. LOW: the asset URL answers an HTTP error: the error body is never installed.
setup asset-http-error 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
touch "$C/releases/asset-v1.23.0.http-error"
run_wrapper
check "http error: existing binary kept" "$(bin_version)" "1.22.0"
if grep -q "Not Found" "$BIN" 2>/dev/null; then bad "http error: error body not installed"; else ok "http error: error body not installed"; fi
has "http error: warning" "$C/err" "download failed, keeping existing binary"

# 24. Round 2, MEDIUM 1: an `unusable` record does not protect a binary that no longer reports
#     a version (replaced from outside by a non-reporting executable): the wrapper downloads.
setup unusable-then-broken 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
echo "garbage" > "$C/releases/asset-v1.23.0.version"
run_wrapper
has "unusable then broken: record says unusable" "$C/home/bin/.CheICalMCP.release" "unusable"
printf '#!/bin/bash\nexit 3\n' > "$BIN"; /bin/chmod u+x "$BIN"
rm "$C/releases/asset-v1.23.0.version"
run_wrapper
check "unusable then broken: downloaded again" "$(downloads)" "2"
check "unusable then broken: repaired" "$(bin_version)" "1.23.0"

# 25. Round 2, MEDIUM 2: two spawns download at once (slow two-stage asset): one download, the
#     new binary, no `unusable` record, no temp file or lock left, both run the new binary.
setup concurrent 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
spawn_bg a SLOW_ASSET=2; sleep 0.3; spawn_bg b SLOW_ASSET=2; wait
check "concurrent: new binary" "$(bin_version)" "1.23.0"
check "concurrent: one download" "$(downloads)" "1"
check "concurrent: record" "$(release_record)" "1.23.0 1.23.0"
check "concurrent: no temp file or lock left" "$(leftovers)" ""
check "concurrent: first spawn runs the new binary" "$(cat "$C/out.a")" "RAN CheICalMCP 1.23.0 req"
check "concurrent: second spawn runs the new binary" "$(cat "$C/out.b")" "RAN CheICalMCP 1.23.0 req"

# 26. Same, on a fresh install.
setup concurrent-fresh 1.23.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
spawn_bg a SLOW_ASSET=2; sleep 0.3; spawn_bg b SLOW_ASSET=2; wait
check "concurrent fresh: new binary" "$(bin_version)" "1.23.0"
check "concurrent fresh: one download" "$(downloads)" "1"
check "concurrent fresh: no temp file or lock left" "$(leftovers)" ""
check "concurrent fresh: second spawn runs the new binary" "$(cat "$C/out.b")" "RAN CheICalMCP 1.23.0 req"

# 27. The lock is held by another wrapper the whole time: after a bounded wait, run the
#     existing binary without downloading, and leave the other wrapper's lock alone.
setup lock-held 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
mkdir "$C/home/bin/.CheICalMCP.lock"
run_wrapper
check "lock held: no download" "$(downloads)" "0"
check "lock held: runs the existing binary" "$(cat "$C/out")" "RAN CheICalMCP 1.22.0 req"
has "lock held: says why" "$C/err" "another wrapper"
[ -d "$C/home/bin/.CheICalMCP.lock" ] && ok "lock held: other wrapper's lock left alone" || bad "lock held: other wrapper's lock left alone"

# 28. Lock held and no binary at all: exit 1 with a message, nothing to run.
setup lock-held-fresh 1.23.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
mkdir -p "$C/home/bin/.CheICalMCP.lock"
run_wrapper
check "lock held, fresh: exit 1" "$RC" "1"
has "lock held, fresh: error" "$C/err" "ERROR"

# 29. A lock older than ten minutes is stale: removed, and the download goes ahead.
setup lock-stale 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
mkdir "$C/home/bin/.CheICalMCP.lock"
touch -t "$(date -v-1H +%Y%m%d%H%M.%S)" "$C/home/bin/.CheICalMCP.lock"
run_wrapper
check "stale lock: downloaded" "$(bin_version)" "1.23.0"
check "stale lock: removed" "$(leftovers)" ""

# 30. LOW 1: during the gap, latest (1.22.0) is older than the installed 1.22.5: kept, two
#     spawns, nothing downloaded.
setup gap-older-latest 1.23.0
install_existing 1.22.5 1.22.5
release_json "$C/releases/latest.json" 1.22.0
run_wrapper; run_wrapper
check "older latest: binary kept" "$(bin_version)" "1.22.5"
check "older latest: no download" "$(downloads)" "0"
check "older latest: sidecar" "$(side)" "1.22.5"

# 31. LOW 1: the pinned asset reports 1.21.0, older than the installed 1.22.0: kept, recorded,
#     one stderr line, not downloaded again.
setup pinned-older-asset 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
echo "CheICalMCP 1.21.0" > "$C/releases/asset-v1.23.0.version"
run_wrapper
check "older asset: binary kept" "$(bin_version)" "1.22.0"
check "older asset: record" "$(release_record)" "1.23.0 1.21.0"
check "older asset: one line about it" "$(grep -c "not newer than the installed" "$C/err" | tr -d ' ')" "1"
check "older asset: no temp file left" "$(leftovers)" ""
run_wrapper
check "older asset: not downloaded again" "$(downloads)" "1"
check "older asset: still kept" "$(bin_version)" "1.22.0"

# 32. LOW 2: during the gap, latest's body has no tag_name (the tag comes from the asset URL):
#     latest is already installed, two spawns, nothing downloaded.
setup gap-no-tag 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/latest.json" 1.22.0 no-tag
run_wrapper; run_wrapper
check "gap, no tag: no download" "$(downloads)" "0"
check "gap, no tag: binary kept" "$(bin_version)" "1.22.0"

# 33. LOW 4: API calls give up after 5 s each; the asset download keeps its long timeout.
api_slow=$(cat "$TMP"/*/curl.log.max-time | grep " https://api.github.com/" | grep -cv "^5 " | tr -d ' ')
check "API calls use --max-time 5" "$api_slow" "0"
asset_mt=$(cat "$TMP"/*/curl.log.max-time | grep "/releases/download/" | awk '{print $1}' | sort -u | tr '\n' ' ')
check "asset download uses --max-time 300" "$asset_mt" "300 "

# 34. Round 3, MEDIUM 1: the binary is replaced by a newer one (make install, --self-update)
#     while the asset downloads: the newer one survives the mv.
setup swapped-mid-download 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
spawn_bg a SLOW_ASSET=2
wait_download_started
fake_binary "$C/newer" 1.24.0; mv "$C/newer" "$BIN"
wait
check "swapped: newer binary survives" "$(bin_version)" "1.24.0"
check "swapped: runs the newer binary" "$(cat "$C/out.a")" "RAN CheICalMCP 1.24.0 req"
has "swapped: says it kept the installed binary" "$C/err.a" "keeping the installed binary"
check "swapped: no temp file or lock left" "$(leftovers)" ""
run_wrapper
check "swapped: next spawn keeps it, no download" "$(downloads)" "1"

# 35. Round 3, MEDIUM 2/3: TERM during the asset download ends the wrapper within a few
#     seconds (not after the download), and leaves no lock or temp file.
setup term-mid-download 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
spawn_bg a SLOW_ASSET=20; pid=$!
wait_download_started
kill -TERM "$pid"
if exits_within "$pid" 3; then ok "TERM: wrapper exits within 3 s"; else bad "TERM: wrapper exits within 3 s"; kill -KILL "$pid" 2>/dev/null; fi
pkill -f "$C/home/bin/CheICalMCP" 2>/dev/null; sleep 0.2
check "TERM: no lock or temp file left" "$(leftovers)" ""
check "TERM: binary untouched" "$(bin_version)" "1.22.0"

# 36. KILL during the download leaves a lock with a dead pid and a temp file: the next spawn
#     takes the lock at once, removes the temp file, and downloads.
setup kill-mid-download 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
spawn_bg a SLOW_ASSET=20; pid=$!
wait_download_started
kill -KILL "$pid"; wait "$pid" 2>/dev/null
pkill -f "$C/home/bin/CheICalMCP" 2>/dev/null; sleep 0.2
[ -d "$C/home/bin/.CheICalMCP.lock" ] && ok "KILL: lock left behind (precondition)" || bad "KILL: lock left behind (precondition)"
start=$(date +%s)
run_wrapper
check "KILL: next spawn did not wait" "$(( $(date +%s) - start < 3 ))" "1"
hasnt "KILL: next spawn did not report a held lock" "$C/err" "another wrapper"
check "KILL: next spawn downloaded" "$(bin_version)" "1.23.0"
check "KILL: no lock or temp file left" "$(leftovers)" ""

# 37. A lock whose pid file names a dead process is taken at once.
setup lock-dead-pid 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
mkdir "$C/home/bin/.CheICalMCP.lock"; dead_pid > "$C/home/bin/.CheICalMCP.lock/pid"
start=$(date +%s)
run_wrapper
check "dead pid: did not wait" "$(( $(date +%s) - start < 3 ))" "1"
check "dead pid: downloaded" "$(bin_version)" "1.23.0"
check "dead pid: lock removed" "$(leftovers)" ""

# 38. Leftover temp files of killed runs are removed while the lock is held.
setup leftover-temp 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
echo partial > "$C/home/bin/CheICalMCP.download.Ab12Cd"
echo keep > "$C/home/bin/CheICalMCP.backup"
run_wrapper
check "leftover temp: removed, other files kept" "$(leftovers)" "CheICalMCP.backup "
check "leftover temp: downloaded" "$(bin_version)" "1.23.0"

# 39. The lock is released only when its pid file still holds the wrapper's own pid.
setup lock-foreign-pid 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
spawn_bg a SLOW_ASSET=2
wait_download_started
echo $$ > "$C/home/bin/.CheICalMCP.lock/pid"
wait
check "foreign pid: download finished" "$(bin_version)" "1.23.0"
check "foreign pid: lock left alone" "$(cat "$C/home/bin/.CheICalMCP.lock/pid" 2>/dev/null)" "$$"
check "foreign pid: temp file removed" "$(leftovers)" ".CheICalMCP.lock "

# 40. LOW: fresh install whose pinned asset reports no version: installed once, and not
#     downloaded again while the installed file is that asset; a different file is replaced.
setup fresh-unusable 1.23.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
echo "garbage" > "$C/releases/asset-v1.23.0.version"
run_wrapper; run_wrapper; run_wrapper
check "fresh unusable: one download over three spawns" "$(downloads)" "1"
has "fresh unusable: says the asset reports no version" "$C/err" "does not report a version"
printf '#!/bin/bash\nexit 3\n' > "$BIN"; /bin/chmod u+x "$BIN"
run_wrapper
check "fresh unusable: a different file is downloaded over" "$(downloads)" "2"

# 41. LOW: the mv over the installed binary fails (here it is immutable): the installed
#     binary is kept, the temp file is removed, no record is written, and nothing says installed.
setup mv-fails 1.23.0
install_existing 1.22.0 1.22.0
release_json "$C/releases/tag-v1.23.0.json" 1.23.0
/usr/bin/chflags uchg "$BIN"
run_wrapper
/usr/bin/chflags nouchg "$BIN"
check "mv fails: installed binary kept" "$(bin_version)" "1.22.0"
check "mv fails: sidecar still the installed version" "$(side)" "1.22.0"
check "mv fails: no release record" "$(release_record)" ""
check "mv fails: nothing left behind" "$(leftovers)" ""
has "mv fails: says it could not replace the binary" "$C/err" "could not replace"
hasnt "mv fails: does not say installed" "$C/err" "installed v1.23.0"

hasnt "no case reached an unexpected URL" <(cat "$TMP"/*/curl.log) "UNEXPECTED"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
