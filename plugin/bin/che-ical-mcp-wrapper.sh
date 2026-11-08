#!/bin/bash
# Version-aware auto-download wrapper for CheICalMCP.
#
# Design (#483):
# - Reads the pinned version from plugin.json (the plugin's intended binary version)
# - Decides from what the installed binary reports (`CheICalMCP --version`), not from the
#   sidecar: downloads when the binary is missing, cannot report a version, or reports one
#   older than the pin; never replaces a binary newer than the pin (--self-update, make install)
# - Tries the pinned release first, then falls back to releases/latest (pin not released yet)
# - One download at a time: the download section holds ~/bin/.CheICalMCP.lock (mkdir). A spawn
#   that finds it held waits a few seconds, then runs whatever is installed without downloading,
#   so the client does not time out; a lock older than 10 minutes is stale and removed
# - Each download goes to its own temp file in ~/bin (mktemp), then an atomic mv; `curl -f` so an
#   HTTP error body is never installed; the downloaded file must report a version, not older
#   than the installed binary's, before it replaces an existing binary
# - ~/bin/.CheICalMCP.version (sidecar) records what the installed binary reports
# - ~/bin/.CheICalMCP.release records the last release downloaded and what its asset reported
#   (`<tag> <version>`, or `<tag> unusable <version kept>`), so a release that offers nothing
#   newer than what is installed is not downloaded again on every spawn. Delete it to retry.
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
LOCK_WAIT_TICKS=20          # × 0.25 s: how long a spawn waits for another wrapper's download
LOCK_STALE_MINUTES=10
API_MAX_TIME=5
ASSET_MAX_TIME=300

# Locate plugin root via wrapper's own path (more reliable than $CLAUDE_PLUGIN_ROOT
# which isn't guaranteed in MCP spawn env). Wrapper lives at PLUGIN_ROOT/bin/*.sh.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

VERSION_RE='^([0-9]+)\.([0-9]+)\.([0-9]+)$'

# Cleanup of what this process created: its temp file, and the lock only if it took it.
TMP_FILE=""
OWN_LOCK=false
cleanup() {
    [[ -n "$TMP_FILE" ]] && rm -f "$TMP_FILE" 2>/dev/null
    $OWN_LOCK && rm -rf "$LOCK_DIR" 2>/dev/null
    TMP_FILE=""
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

# release_offers_nothing_newer TAG → true when downloading release TAG cannot improve on the
# installed binary. Requires a binary that reports a version: a missing or non-reporting
# binary is always worth replacing. Then: the tag is not newer than that version, or TAG was
# the last release downloaded and its asset reported a version not newer than it, or its asset
# reported none while this same version was kept.
release_offers_nothing_newer() {
    [[ -n "$1" ]] && [[ -n "$ACTUAL_VERSION" ]] || return 1
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
    LAST_RELEASE_TAG="" LAST_RELEASE_REPORTED="" LAST_RELEASE_KEPT=""
    [[ -f "$RELEASE_FILE" ]] && read -r LAST_RELEASE_TAG LAST_RELEASE_REPORTED LAST_RELEASE_KEPT _ < "$RELEASE_FILE" 2>/dev/null
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
            NOTE="WARNING — plugin wants v${DESIRED_VERSION}; the asset of release v${DESIRED_VERSION} does not report a version, keeping v${ACTUAL_VERSION} (delete $RELEASE_FILE to retry)"
        else
            NOTE="WARNING — plugin wants v${DESIRED_VERSION}; release v${DESIRED_VERSION} ships v${LAST_RELEASE_REPORTED}, keeping v${ACTUAL_VERSION} (delete $RELEASE_FILE to retry)"
        fi
    else
        NEED_DOWNLOAD=true
        REASON="plugin wants v${DESIRED_VERSION}, binary reports v${ACTUAL_VERSION:-unknown}"
    fi
    return 0
}

# take_lock → 0 when this process holds the download lock; 1 after waiting for another
# wrapper's lock (bounded), which this process then leaves alone.
take_lock() {
    mkdir -p "$INSTALL_DIR"
    if mkdir "$LOCK_DIR" 2>/dev/null; then OWN_LOCK=true; echo $$ > "$LOCK_DIR/pid"; return 0; fi
    if find "$LOCK_DIR" -maxdepth 0 -mmin +"$LOCK_STALE_MINUTES" 2>/dev/null | grep -q .; then
        echo "$BINARY_NAME: removing a stale download lock (older than $LOCK_STALE_MINUTES minutes)" >&2
        rm -rf "$LOCK_DIR" 2>/dev/null
        if mkdir "$LOCK_DIR" 2>/dev/null; then OWN_LOCK=true; echo $$ > "$LOCK_DIR/pid"; return 0; fi
    fi
    local i=0
    while [[ -d "$LOCK_DIR" ]] && (( i < LOCK_WAIT_TICKS )); do sleep 0.25; i=$((i + 1)); done
    return 1
}

# download: fetch the release to install, probe it, and install or keep. Runs under the lock.
download() {
    echo "$BINARY_NAME: $REASON — downloading from $REPO..." >&2

    # Try pinned tag first, then fall back to latest release.
    local URL="" FETCHED_VERSION="" API_URL RELEASE_JSON REPORTED_VERSION
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
        echo "$BINARY_NAME: WARNING — v${DESIRED_VERSION:-latest} has no release yet; keeping installed v${ACTUAL_VERSION} (latest is v${FETCHED_VERSION})" >&2
        return 0
    fi

    TMP_FILE=$(mktemp "${BINARY}.XXXXXX" 2>/dev/null) || TMP_FILE=""
    if [[ -z "$TMP_FILE" ]] || ! curl -fsSL --max-time "$ASSET_MAX_TIME" "$URL" -o "$TMP_FILE" 2>/dev/null; then
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
    if [[ -z "$REPORTED_VERSION" ]] && [[ -n "$ACTUAL_VERSION" ]]; then
        echo "${FETCHED_VERSION:-unknown} unusable $ACTUAL_VERSION" > "$RELEASE_FILE"
        cleanup_tmp
        echo "$BINARY_NAME: WARNING — the asset of release v${FETCHED_VERSION:-unknown} does not report a version; keeping existing binary v${ACTUAL_VERSION}" >&2
        return 0
    fi
    echo "${FETCHED_VERSION:-unknown} ${REPORTED_VERSION:-unusable}" > "$RELEASE_FILE"
    if [[ -n "$REPORTED_VERSION" ]] && [[ -n "$ACTUAL_VERSION" ]] \
        && [[ "$(compare_versions "$REPORTED_VERSION" "$ACTUAL_VERSION")" -lt 0 ]]; then
        cleanup_tmp
        echo "$BINARY_NAME: WARNING — release v${FETCHED_VERSION:-unknown} ships v${REPORTED_VERSION}, older than the installed v${ACTUAL_VERSION}; keeping the installed binary" >&2
        return 0
    fi
    mv "$TMP_FILE" "$BINARY"
    TMP_FILE=""
    echo "${REPORTED_VERSION:-unknown}" > "$VERSION_FILE"
    if [[ -n "$DESIRED_VERSION" ]] && [[ "$FETCHED_VERSION" != "$DESIRED_VERSION" ]]; then
        echo "$BINARY_NAME: WARNING — plugin wants v${DESIRED_VERSION}, which has no release yet; installed release v${FETCHED_VERSION:-unknown}, which ships v${REPORTED_VERSION:-unknown}" >&2
    elif [[ -n "$DESIRED_VERSION" ]] && [[ "$REPORTED_VERSION" != "$DESIRED_VERSION" ]]; then
        echo "$BINARY_NAME: WARNING — plugin wants v${DESIRED_VERSION}; release v${FETCHED_VERSION} ships v${REPORTED_VERSION:-unknown}, installed it" >&2
    else
        echo "$BINARY_NAME: installed v${REPORTED_VERSION:-unknown}" >&2
    fi
    return 0
}
cleanup_tmp() { [[ -n "$TMP_FILE" ]] && rm -f "$TMP_FILE" 2>/dev/null; TMP_FILE=""; }

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
