#!/bin/bash
# Version-aware auto-download wrapper for CheICalMCP.
#
# Design (#483):
# - Reads the pinned version from plugin.json (the plugin's intended binary version)
# - Decides from what the installed binary reports (`CheICalMCP --version`), not from the
#   sidecar: downloads when the binary is missing, cannot report a version, or reports one
#   older than the pin; never replaces a binary newer than the pin (--self-update, make install)
# - Tries the pinned release first, then falls back to releases/latest (pin not released yet)
# - Atomic file swap (.tmp + mv) so partial downloads never break things; `curl -f` so an
#   HTTP error body is never installed; the downloaded file must report a version before it
#   replaces an existing binary
# - ~/bin/.CheICalMCP.version (sidecar) records what the installed binary reports
# - ~/bin/.CheICalMCP.release records the last release downloaded and what its asset reported
#   (`<tag> <version|unusable>`), so a release whose asset reports another version than its
#   tag, or none, is downloaded once and not again on every spawn
# - While the pinned release does not exist, each spawn makes up to two small API calls
#   (pinned tag, latest) and downloads nothing when latest is already installed
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

# Locate plugin root via wrapper's own path (more reliable than $CLAUDE_PLUGIN_ROOT
# which isn't guaranteed in MCP spawn env). Wrapper lives at PLUGIN_ROOT/bin/*.sh.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

VERSION_RE='^([0-9]+)\.([0-9]+)\.([0-9]+)$'

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

# The release's tag from a GitHub release JSON on stdin, without a leading `v`; empty if absent.
release_version() {
    grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4 | sed 's/^v//'
}

# installed_from_release TAG → true when the installed binary is what release TAG ships:
# it reports TAG itself, or TAG was the last release downloaded and the binary reports what
# that release's asset reported (or the asset reported nothing and the binary was kept).
installed_from_release() {
    [[ -n "$1" ]] || return 1
    [[ -n "$ACTUAL_VERSION" ]] && [[ "$1" == "$ACTUAL_VERSION" ]] && return 0
    [[ "$LAST_RELEASE_TAG" == "$1" ]] || return 1
    [[ "$LAST_RELEASE_REPORTED" == unusable ]] && return 0
    [[ -n "$ACTUAL_VERSION" ]] && [[ "$LAST_RELEASE_REPORTED" == "$ACTUAL_VERSION" ]]
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

# The sidecar, the last release downloaded, and what the installed binary reports.
INSTALLED_VERSION=""
[[ -f "$VERSION_FILE" ]] && INSTALLED_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)
LAST_RELEASE_TAG=""
LAST_RELEASE_REPORTED=""
[[ -f "$RELEASE_FILE" ]] && read -r LAST_RELEASE_TAG LAST_RELEASE_REPORTED _ < "$RELEASE_FILE" 2>/dev/null
ACTUAL_VERSION=""
[[ -x "$BINARY" ]] && ACTUAL_VERSION=$(reported_version "$BINARY")

# Keep the sidecar equal to what the binary reports.
if [[ -n "$ACTUAL_VERSION" ]] && [[ "$INSTALLED_VERSION" != "$ACTUAL_VERSION" ]]; then
    echo "$ACTUAL_VERSION" > "$VERSION_FILE" 2>/dev/null
fi

# Decide whether to download.
NEED_DOWNLOAD=false
REASON=""
if [[ ! -x "$BINARY" ]]; then
    NEED_DOWNLOAD=true
    REASON="binary not installed"
elif [[ -z "$DESIRED_VERSION" ]]; then
    :   # no pin: keep whatever is installed
elif [[ -n "$ACTUAL_VERSION" ]] && [[ "$(compare_versions "$ACTUAL_VERSION" "$DESIRED_VERSION")" -ge 0 ]]; then
    if [[ "$ACTUAL_VERSION" != "$DESIRED_VERSION" ]]; then
        echo "$BINARY_NAME: installed binary v${ACTUAL_VERSION} is newer than the plugin pin v${DESIRED_VERSION}; keeping it" >&2
    fi
elif installed_from_release "$DESIRED_VERSION"; then
    # The pinned release was downloaded before and what it ships is installed (its asset
    # reports another version than its tag, or none): downloading it again changes nothing.
    if [[ "$LAST_RELEASE_REPORTED" == unusable ]]; then
        echo "$BINARY_NAME: WARNING — plugin wants v${DESIRED_VERSION}; the asset of release v${DESIRED_VERSION} does not report a version, keeping existing binary" >&2
    else
        echo "$BINARY_NAME: WARNING — plugin wants v${DESIRED_VERSION}; release v${DESIRED_VERSION} ships v${LAST_RELEASE_REPORTED}, already installed" >&2
    fi
else
    NEED_DOWNLOAD=true
    REASON="plugin wants v${DESIRED_VERSION}, binary reports v${ACTUAL_VERSION:-unknown}"
fi

if $NEED_DOWNLOAD; then
    echo "$BINARY_NAME: $REASON — downloading from $REPO..." >&2
    mkdir -p "$INSTALL_DIR"

    # Try pinned tag first, then fall back to latest release.
    URL=""
    FETCHED_VERSION=""
    for API_URL in \
        "${DESIRED_VERSION:+https://api.github.com/repos/$REPO/releases/tags/v$DESIRED_VERSION}" \
        "https://api.github.com/repos/$REPO/releases/latest"
    do
        [[ -z "$API_URL" ]] && continue
        RELEASE_JSON=$(curl -sL --max-time 30 "$API_URL" 2>/dev/null || true)
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
        else
            echo "$BINARY_NAME: ERROR — no download URL found at $REPO. Install manually: https://github.com/$REPO/releases" >&2
            exit 1
        fi
    elif [[ -x "$BINARY" ]] && installed_from_release "$FETCHED_VERSION"; then
        # The release found is what is already installed (typically: the pinned tag has no
        # release yet and latest is what we have). Nothing to download.
        echo "$BINARY_NAME: WARNING — v${DESIRED_VERSION:-latest} has no release yet; keeping installed v${ACTUAL_VERSION:-unknown} (release v${FETCHED_VERSION})" >&2
    elif curl -fsSL --max-time 300 "$URL" -o "${BINARY}.tmp" 2>/dev/null; then
        chmod +x "${BINARY}.tmp"
        REPORTED_VERSION=$(reported_version "${BINARY}.tmp")
        # Remember this release and what it ships, whatever happens next, so it is not
        # downloaded again on every spawn.
        echo "${FETCHED_VERSION:-unknown} ${REPORTED_VERSION:-unusable}" > "$RELEASE_FILE"
        if [[ -z "$REPORTED_VERSION" ]] && [[ -x "$BINARY" ]]; then
            rm -f "${BINARY}.tmp" 2>/dev/null
            echo "$BINARY_NAME: WARNING — the asset of release v${FETCHED_VERSION:-unknown} does not report a version; keeping existing binary" >&2
        else
            mv "${BINARY}.tmp" "$BINARY"
            echo "${REPORTED_VERSION:-unknown}" > "$VERSION_FILE"
            if [[ -n "$DESIRED_VERSION" ]] && [[ "$FETCHED_VERSION" != "$DESIRED_VERSION" ]]; then
                echo "$BINARY_NAME: WARNING — plugin wants v${DESIRED_VERSION}, which has no release yet; installed release v${FETCHED_VERSION:-unknown}, which ships v${REPORTED_VERSION:-unknown}" >&2
            elif [[ -n "$DESIRED_VERSION" ]] && [[ "$REPORTED_VERSION" != "$DESIRED_VERSION" ]]; then
                echo "$BINARY_NAME: WARNING — plugin wants v${DESIRED_VERSION}; release v${FETCHED_VERSION} ships v${REPORTED_VERSION:-unknown}, installed it" >&2
            else
                echo "$BINARY_NAME: installed v${REPORTED_VERSION:-unknown}" >&2
            fi
        fi
    else
        rm -f "${BINARY}.tmp" 2>/dev/null
        if [[ -x "$BINARY" ]]; then
            echo "$BINARY_NAME: WARNING — download failed, keeping existing binary" >&2
        else
            echo "$BINARY_NAME: ERROR — download failed" >&2
            exit 1
        fi
    fi
fi

exec "$BINARY" "$@"
