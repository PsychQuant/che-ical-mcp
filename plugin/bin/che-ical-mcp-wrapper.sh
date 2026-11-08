#!/bin/bash
# Version-aware auto-download wrapper for CheICalMCP.
#
# Design (#483):
# - Reads the pinned version from plugin.json (the plugin's intended binary version)
# - Decides from what the installed binary reports (`CheICalMCP --version`), not from the
#   sidecar: downloads when the binary is missing, cannot report a version, or reports one
#   older than the pin; never replaces a binary newer than the pin (--self-update, make install)
# - Tries the pinned release first, then falls back to releases/latest (pin not released yet)
# - One download at a time: the download section holds ~/bin/.CheICalMCP.lock (mkdir, with the
#   holder's pid inside). A lock whose pid is dead, or that is older than 10 minutes, is stale and
#   taken over at once. A spawn that finds a live lock waits up to 5 s, then runs whatever is
#   installed without downloading, so the client does not time out. The lock is removed only by
#   the process whose pid it holds.
# - The asset is downloaded in the background and waited for, so a TERM (the client giving up)
#   ends the wrapper at once: the trap stops curl and removes the temp file and the lock.
#   Temp files (~/bin/CheICalMCP.download.XXXXXX) left by a killed run are removed under the lock.
# - `curl -f`, so an HTTP error body is never installed. Right before the mv the installed binary
#   is probed again: an asset that reports no version, or one not newer than what is installed at
#   that moment, does not replace a binary that reports a version.
# - ~/bin/.CheICalMCP.version (sidecar) records what the installed binary reports
# - ~/bin/.CheICalMCP.release records the last release downloaded: `<tag> <version>` (what its
#   asset reported), `<tag> unusable <version kept>`, or `<tag> unusable - <cksum>` (an asset
#   that reports no version, installed because nothing that reports one was there). While it
#   describes what is installed (a version not older than the asset's, the version kept, or the
#   same file by cksum), that release is not downloaded again. Delete it to make the wrapper
#   retry. A failed download writes no record and is retried on the next spawn.
# - API calls give up after 5 s each; while the pinned release does not exist, each spawn makes
#   up to two of them (pinned tag, latest) and downloads nothing when latest is not newer
# - Every `--version` probe reads /dev/null: stdin is the MCP channel
#
# Tests: bash scripts/tests/plugin-wrapper-test.sh (stubbed curl, temp HOME).

set -u

REPO="PsychQuant/che-ical-mcp"
BINARY_NAME="CheICalMCP"
INSTALL_DIR="$HOME/bin"
BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"
RELEASE_FILE="$INSTALL_DIR/.${BINARY_NAME}.release"
LOCK_DIR="$INSTALL_DIR/.${BINARY_NAME}.lock"
TMP_PREFIX="${BINARY}.download."
LOCK_WAIT_TICKS=20          # × 0.25 s: how long a spawn waits for another wrapper's download
LOCK_STALE_MINUTES=10
API_MAX_TIME=5
ASSET_MAX_TIME=300

# Locate plugin root via wrapper's own path (more reliable than $CLAUDE_PLUGIN_ROOT
# which isn't guaranteed in MCP spawn env). Wrapper lives at PLUGIN_ROOT/bin/*.sh.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

VERSION_RE='^([0-9]+)\.([0-9]+)\.([0-9]+)$'

# Cleanup of what this process created: the background curl, its temp file, and the lock
# only if the lock still names this process.
TMP_FILE=""
CURL_PID=""
OWN_LOCK=false
cleanup() {
    if [[ -n "$CURL_PID" ]]; then
        kill "$CURL_PID" 2>/dev/null
        wait "$CURL_PID" 2>/dev/null
        CURL_PID=""
    fi
    cleanup_tmp
    release_lock
}
cleanup_tmp() { [[ -n "$TMP_FILE" ]] && rm -f "$TMP_FILE" 2>/dev/null; TMP_FILE=""; }
release_lock() {
    if $OWN_LOCK && [[ "$(lock_pid)" == "$$" ]]; then
        rm -rf "$LOCK_DIR" 2>/dev/null
    fi
    OWN_LOCK=false
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# What a binary reports for itself: `CheICalMCP X.Y.Z` on stdout → `X.Y.Z`. Empty when it
# cannot run or prints something else. `--version` reads no calendar data; stdin is
# /dev/null and stderr (where a startup line can appear) is discarded.
reported_version() {
    local out
    out=$("$1" --version </dev/null 2>/dev/null | head -1 || true)
    if [[ "$out" =~ ^${BINARY_NAME}[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$ ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# A file's CRC and size from cksum (base macOS), as `<crc>-<size>`; empty if unreadable.
file_sum() {
    [[ -f "$1" ]] || return 0
    cksum < "$1" 2>/dev/null | awk '{print $1 "-" $2}'
}

# compare_versions A B → prints -1, 0 or 1 (numeric x.y.z; both must match VERSION_RE).
compare_versions() {
    local a b i
    [[ "$1" =~ $VERSION_RE ]] && a=("${BASH_REMATCH[@]:1}")
    [[ "$2" =~ $VERSION_RE ]] && b=("${BASH_REMATCH[@]:1}")
    for i in 0 1 2; do
        if (( 10#${a[$i]} < 10#${b[$i]} )); then echo -1; return; fi
        if (( 10#${a[$i]} > 10#${b[$i]} )); then echo 1; return; fi
    done
    echo 0
}

# not_newer A B → true when A and B are both x.y.z and A <= B.
not_newer() {
    [[ "$1" =~ $VERSION_RE ]] && [[ "$2" =~ $VERSION_RE ]] && [[ "$(compare_versions "$1" "$2")" -le 0 ]]
}

# The release's tag from a GitHub release JSON on stdin, without a leading `v`; empty if absent.
release_version() {
    grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4 | sed 's/^v//'
}

# release_offers_nothing_newer TAG → true when downloading release TAG cannot improve on what
# is installed:
# - the installed binary reports a version, and the tag is not newer than it; or TAG is the
#   recorded release and its asset reported a version not newer than it, or reported none
#   while this same version was kept;
# - the installed binary reports no version, TAG is the recorded release, its asset reported
#   none, and the installed file is that asset (same cksum).
release_offers_nothing_newer() {
    [[ -n "$1" ]] || return 1
    if [[ -z "$ACTUAL_VERSION" ]]; then
        [[ -x "$BINARY" ]] && [[ "$LAST_RELEASE_TAG" == "$1" ]] && [[ "$LAST_RELEASE_REPORTED" == unusable ]] \
            && [[ -n "$LAST_RELEASE_SUM" ]] && [[ "$LAST_RELEASE_SUM" == "$(file_sum "$BINARY")" ]]
        return
    fi
    not_newer "$1" "$ACTUAL_VERSION" && return 0
    [[ "$LAST_RELEASE_TAG" == "$1" ]] || return 1
    if [[ "$LAST_RELEASE_REPORTED" == unusable ]]; then
        [[ "$LAST_RELEASE_KEPT" == "$ACTUAL_VERSION" ]]
        return
    fi
    not_newer "$LAST_RELEASE_REPORTED" "$ACTUAL_VERSION"
}

# Read the pinned version from plugin.json (empty on any failure → no pin, latest only).
DESIRED_VERSION=""
if [[ -f "$PLUGIN_JSON" ]]; then
    DESIRED_VERSION=$(grep -oE '"version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
        | head -1 | cut -d'"' -f4 || true)
fi
if [[ -n "$DESIRED_VERSION" ]] && ! [[ "$DESIRED_VERSION" =~ $VERSION_RE ]]; then
    echo "$BINARY_NAME: WARNING — plugin.json version '$DESIRED_VERSION' is not x.y.z; not pinning" >&2
    DESIRED_VERSION=""
fi

# load_state: the last release downloaded and what the installed binary reports; keeps the
# sidecar equal to the latter.
load_state() {
    LAST_RELEASE_TAG="" LAST_RELEASE_REPORTED="" LAST_RELEASE_KEPT="" LAST_RELEASE_SUM=""
    [[ -f "$RELEASE_FILE" ]] && read -r LAST_RELEASE_TAG LAST_RELEASE_REPORTED LAST_RELEASE_KEPT LAST_RELEASE_SUM _ \
        < "$RELEASE_FILE" 2>/dev/null
    ACTUAL_VERSION=""
    [[ -x "$BINARY" ]] && ACTUAL_VERSION=$(reported_version "$BINARY")
    local sidecar=""
    [[ -f "$VERSION_FILE" ]] && sidecar=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)
    if [[ -n "$ACTUAL_VERSION" ]] && [[ "$sidecar" != "$ACTUAL_VERSION" ]]; then
        echo "$ACTUAL_VERSION" > "$VERSION_FILE" 2>/dev/null
    fi
    return 0
}

# decide: sets NEED_DOWNLOAD, REASON, and NOTE (a stderr line to print when not downloading).
decide() {
    NEED_DOWNLOAD=false REASON="" NOTE=""
    if [[ ! -x "$BINARY" ]]; then
        NEED_DOWNLOAD=true
        REASON="binary not installed"
    elif [[ -z "$DESIRED_VERSION" ]]; then
        :   # no pin: keep whatever is installed
    elif [[ -n "$ACTUAL_VERSION" ]] && not_newer "$DESIRED_VERSION" "$ACTUAL_VERSION"; then
        [[ "$ACTUAL_VERSION" != "$DESIRED_VERSION" ]] && \
            NOTE="installed binary v${ACTUAL_VERSION} is newer than the plugin pin v${DESIRED_VERSION}; keeping it"
    elif release_offers_nothing_newer "$DESIRED_VERSION"; then
        # The pinned release was downloaded before and offers nothing newer than what is installed.
        if [[ "$LAST_RELEASE_REPORTED" == unusable ]]; then
            NOTE="WARNING — plugin wants v${DESIRED_VERSION}; the asset of release v${DESIRED_VERSION} does not report a version, keeping what is installed (delete $RELEASE_FILE to retry)"
        else
            NOTE="WARNING — plugin wants v${DESIRED_VERSION}; release v${DESIRED_VERSION} ships v${LAST_RELEASE_REPORTED}, keeping v${ACTUAL_VERSION} (delete $RELEASE_FILE to retry)"
        fi
    else
        NEED_DOWNLOAD=true
        REASON="plugin wants v${DESIRED_VERSION}, binary reports v${ACTUAL_VERSION:-unknown}"
    fi
    return 0
}

# The pid in the lock's pid file (digits only; empty if none).
lock_pid() { tr -cd '0-9' < "$LOCK_DIR/pid" 2>/dev/null; }

# lock_is_stale → true when the lock's holder is gone: its pid file names a dead process, it has
# no pid file and is over a minute old (killed between mkdir and writing the pid), or it is
# older than LOCK_STALE_MINUTES.
lock_is_stale() {
    local pid
    pid=$(lock_pid)
    if [[ -n "$pid" ]]; then
        kill -0 "$pid" 2>/dev/null || return 0
    elif find "$LOCK_DIR" -maxdepth 0 -mmin +1 2>/dev/null | grep -q .; then
        return 0
    fi
    find "$LOCK_DIR" -maxdepth 0 -mmin +"$LOCK_STALE_MINUTES" 2>/dev/null | grep -q .
}

try_mkdir_lock() {
    mkdir "$LOCK_DIR" 2>/dev/null || return 1
    OWN_LOCK=true
    echo $$ > "$LOCK_DIR/pid"
}

# take_lock → 0 when this process holds the download lock; 1 after waiting for another
# wrapper's lock (bounded), which this process then leaves alone.
take_lock() {
    mkdir -p "$INSTALL_DIR"
    try_mkdir_lock && return 0
    if lock_is_stale; then
        echo "$BINARY_NAME: removing a stale download lock (holder gone)" >&2
        rm -rf "$LOCK_DIR" 2>/dev/null
        try_mkdir_lock && return 0
    fi
    local i=0
    while [[ -d "$LOCK_DIR" ]] && (( i < LOCK_WAIT_TICKS )); do sleep 0.25; i=$((i + 1)); done
    return 1
}

# fetch_asset URL → downloads into a new temp file ($TMP_FILE) in the background and waits for
# it, so a trapped signal interrupts the wait instead of waiting for curl.
fetch_asset() {
    local f rc
    for f in "${TMP_PREFIX}"??????; do [[ -e "$f" ]] && rm -f "$f" 2>/dev/null; done
    TMP_FILE=$(mktemp "${TMP_PREFIX}XXXXXX" 2>/dev/null) || { TMP_FILE=""; return 1; }
    curl -fsSL --max-time "$ASSET_MAX_TIME" "$1" -o "$TMP_FILE" 2>/dev/null </dev/null &
    CURL_PID=$!
    wait "$CURL_PID"
    rc=$?
    CURL_PID=""
    return "$rc"
}

# download: fetch the release to install, probe it, and install or keep. Runs under the lock.
download() {
    echo "$BINARY_NAME: $REASON — downloading from $REPO..." >&2

    # Try pinned tag first, then fall back to latest release.
    local URL="" FETCHED_VERSION="" API_URL RELEASE_JSON REPORTED_VERSION INSTALLED_NOW
    for API_URL in \
        "${DESIRED_VERSION:+https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION}" \
        "https://api.github.com/repos/$REPO/releases/latest"
    do
        [[ -z "$API_URL" ]] && continue
        RELEASE_JSON=$(curl -sL --max-time "$API_MAX_TIME" "$API_URL" 2>/dev/null || true)
        URL=$(printf '%s\n' "$RELEASE_JSON" \
            | grep '"browser_download_url"' | grep "/$BINARY_NAME\"" | head -1 \
            | sed 's/.*"\(https[^"]*\)".*/\1/')
        if [[ -n "$URL" ]]; then
            FETCHED_VERSION=$(printf '%s\n' "$RELEASE_JSON" | release_version)
            # No tag_name: the pinned endpoint only answers for the pinned tag; otherwise
            # take the tag from the asset URL (.../releases/download/<tag>/CheICalMCP).
            if [[ -z "$FETCHED_VERSION" ]] && [[ "$API_URL" == */releases/tags/* ]]; then
                FETCHED_VERSION="$DESIRED_VERSION"
            elif [[ -z "$FETCHED_VERSION" ]] && [[ "$URL" =~ /releases/download/v?([^/]+)/${BINARY_NAME}$ ]]; then
                FETCHED_VERSION="${BASH_REMATCH[1]}"
            fi
            break
        fi
    done

    if [[ -z "$URL" ]]; then
        if [[ -x "$BINARY" ]]; then
            echo "$BINARY_NAME: WARNING — no download URL found, keeping existing binary" >&2
            return 0
        fi
        echo "$BINARY_NAME: ERROR — no download URL found at $REPO. Install manually: https://github.com/$REPO/releases" >&2
        return 1
    fi
    if [[ -x "$BINARY" ]] && release_offers_nothing_newer "$FETCHED_VERSION"; then
        # The release found offers nothing newer than what is installed (typically: the pinned
        # tag has no release yet and latest is what we have). Nothing to download.
        echo "$BINARY_NAME: WARNING — v${DESIRED_VERSION:-latest} has no release yet; keeping installed v${ACTUAL_VERSION:-unknown} (latest is v${FETCHED_VERSION})" >&2
        return 0
    fi

    if ! fetch_asset "$URL"; then
        cleanup_tmp
        if [[ -x "$BINARY" ]]; then
            echo "$BINARY_NAME: WARNING — download failed, keeping existing binary" >&2
            return 0
        fi
        echo "$BINARY_NAME: ERROR — download failed" >&2
        return 1
    fi

    # The temp file is this process's own and curl finished writing it: the probe is final.
    chmod +x "$TMP_FILE"
    REPORTED_VERSION=$(reported_version "$TMP_FILE")
    # What is installed now: make install or --self-update may have replaced it meanwhile.
    INSTALLED_NOW=""
    [[ -x "$BINARY" ]] && INSTALLED_NOW=$(reported_version "$BINARY")
    if [[ -z "$REPORTED_VERSION" ]] && [[ -n "$INSTALLED_NOW" ]]; then
        echo "${FETCHED_VERSION:-unknown} unusable $INSTALLED_NOW" > "$RELEASE_FILE"
        cleanup_tmp
        echo "$BINARY_NAME: WARNING — the asset of release v${FETCHED_VERSION:-unknown} does not report a version; keeping the installed binary v${INSTALLED_NOW}" >&2
        return 0
    fi
    if [[ -n "$REPORTED_VERSION" ]] && [[ -n "$INSTALLED_NOW" ]] && not_newer "$REPORTED_VERSION" "$INSTALLED_NOW"; then
        echo "${FETCHED_VERSION:-unknown} $REPORTED_VERSION" > "$RELEASE_FILE"
        cleanup_tmp
        echo "$BINARY_NAME: WARNING — release v${FETCHED_VERSION:-unknown} ships v${REPORTED_VERSION}, not newer than the installed v${INSTALLED_NOW}; keeping the installed binary" >&2
        return 0
    fi
    local record
    if [[ -n "$REPORTED_VERSION" ]]; then
        record="${FETCHED_VERSION:-unknown} $REPORTED_VERSION"
    else
        record="${FETCHED_VERSION:-unknown} unusable - $(file_sum "$TMP_FILE")"
    fi
    # The record and the sidecar describe what is installed, so they are written only after
    # the mv succeeds. A failed mv (an immutable or busy target) keeps the installed binary
    # and writes no record, so the next spawn tries again and says so again.
    if ! mv "$TMP_FILE" "$BINARY" 2>/dev/null; then
        cleanup_tmp
        echo "$BINARY_NAME: ERROR — could not replace $BINARY with release v${FETCHED_VERSION:-unknown}; keeping the installed binary" >&2
        return 0
    fi
    TMP_FILE=""
    echo "$record" > "$RELEASE_FILE"
    echo "${REPORTED_VERSION:-unknown}" > "$VERSION_FILE"
    if [[ -z "$REPORTED_VERSION" ]]; then
        echo "$BINARY_NAME: WARNING — the asset of release v${FETCHED_VERSION:-unknown} does not report a version; installed it because nothing that reports one was installed" >&2
    elif [[ -n "$DESIRED_VERSION" ]] && [[ "$FETCHED_VERSION" != "$DESIRED_VERSION" ]]; then
        echo "$BINARY_NAME: WARNING — plugin wants v${DESIRED_VERSION}, which has no release yet; installed release v${FETCHED_VERSION:-unknown}, which ships v${REPORTED_VERSION}" >&2
    elif [[ -n "$DESIRED_VERSION" ]] && [[ "$REPORTED_VERSION" != "$DESIRED_VERSION" ]]; then
        echo "$BINARY_NAME: WARNING — plugin wants v${DESIRED_VERSION}; release v${FETCHED_VERSION} ships v${REPORTED_VERSION}, installed it" >&2
    else
        echo "$BINARY_NAME: installed v${REPORTED_VERSION}" >&2
    fi
    return 0
}

load_state
decide
if $NEED_DOWNLOAD; then
    if take_lock; then
        # Another wrapper may have finished a download just before the lock was free.
        load_state
        decide
        if $NEED_DOWNLOAD; then
            download || exit 1
            NOTE=""
        fi
    else
        # Another wrapper is downloading. Run what is installed now rather than wait for it.
        load_state
        decide
        if $NEED_DOWNLOAD; then
            if [[ -x "$BINARY" ]]; then
                NOTE="WARNING — another wrapper is downloading; running the installed v${ACTUAL_VERSION:-unknown} for now"
            else
                echo "$BINARY_NAME: ERROR — another wrapper is still installing $BINARY_NAME; try again shortly" >&2
                exit 1
            fi
        fi
    fi
fi
[[ -n "$NOTE" ]] && echo "$BINARY_NAME: $NOTE" >&2

cleanup
trap - EXIT
exec "$BINARY" "$@"
