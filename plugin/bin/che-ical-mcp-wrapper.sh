#!/bin/bash
# Version-aware auto-download wrapper for CheICalMCP.
#
# Design:
# - Reads desired version from plugin.json (plugin's intended binary version)
# - Compares against ~/bin/.CheICalMCP.version sidecar, and checks the sidecar against
#   the binary's own `--version` before trusting it (#483)
# - Re-downloads when plugin has been updated but binary is stale
# - Atomic file swap (.tmp + mv) so partial downloads never break things
# - Falls back to releases/latest if plugin.json unreadable or pinned tag missing
# - The sidecar records the release actually installed (its tag_name), never the pin it
#   wanted: after a fallback to latest it holds the latest tag, or `unknown` when the tag
#   cannot be read, so the pinned release is fetched once it exists (#483)
#
# Tests: bash scripts/tests/plugin-wrapper-test.sh (stubbed curl, temp HOME).

set -u

REPO="PsychQuant/che-ical-mcp"
BINARY_NAME="CheICalMCP"
INSTALL_DIR="$HOME/bin"
BINARY="$INSTALL_DIR/$BINARY_NAME"
VERSION_FILE="$INSTALL_DIR/.${BINARY_NAME}.version"

# Locate plugin root via wrapper's own path (more reliable than $CLAUDE_PLUGIN_ROOT
# which isn't guaranteed in MCP spawn env). Wrapper lives at PLUGIN_ROOT/bin/*.sh.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

# The version the binary reports for itself: `CheICalMCP X.Y.Z` on stdout → `X.Y.Z`.
# Empty when the binary cannot run or prints something else. `--version` reads no
# calendar data; stderr (where a startup line can appear) is discarded.
binary_version() {
    local out
    out=$("$BINARY" --version 2>/dev/null | head -1 || true)
    if [[ "$out" =~ ^${BINARY_NAME}[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*)[[:space:]]*$ ]]; then
        echo "${BASH_REMATCH[1]}"
    fi
}

# The release's tag from a GitHub release JSON on stdin, without a leading `v`; empty if absent.
release_version() {
    grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4 | sed 's/^v//'
}

# Read desired version from plugin.json (empty string on any failure → fallback to "latest").
DESIRED_VERSION=""
if [[ -f "$PLUGIN_JSON" ]]; then
    DESIRED_VERSION=$(grep -oE '"version":[[:space:]]*"[^"]+"' "$PLUGIN_JSON" 2>/dev/null \
        | head -1 | cut -d'"' -f4 || true)
fi

# Read currently installed version from sidecar (empty string if file missing/unreadable).
INSTALLED_VERSION=""
[[ -f "$VERSION_FILE" ]] && INSTALLED_VERSION=$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)

# What the installed binary says it is (empty if it is missing or cannot answer).
ACTUAL_VERSION=""
[[ -x "$BINARY" ]] && ACTUAL_VERSION=$(binary_version)

# Decide whether to download.
NEED_DOWNLOAD=false
REASON=""
if [[ ! -x "$BINARY" ]]; then
    NEED_DOWNLOAD=true
    REASON="binary not installed"
elif [[ -n "$DESIRED_VERSION" ]] && [[ "$INSTALLED_VERSION" != "$DESIRED_VERSION" ]]; then
    NEED_DOWNLOAD=true
    REASON="plugin wants v${DESIRED_VERSION}, installed is v${INSTALLED_VERSION:-unknown}"
elif [[ -n "$DESIRED_VERSION" ]] && [[ "$ACTUAL_VERSION" != "$DESIRED_VERSION" ]]; then
    # #483: the sidecar matches the pin but the binary disagrees (an earlier wrapper wrote
    # the pin after falling back to an older release), so the sidecar is not trusted.
    NEED_DOWNLOAD=true
    REASON="plugin wants v${DESIRED_VERSION}, sidecar says v${INSTALLED_VERSION} but the binary reports v${ACTUAL_VERSION:-unknown}"
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
            # The pinned endpoint only answers for the pinned tag.
            [[ -z "$FETCHED_VERSION" ]] && [[ "$API_URL" == */releases/tags/* ]] && FETCHED_VERSION="$DESIRED_VERSION"
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
    elif [[ -x "$BINARY" ]] && [[ -n "$FETCHED_VERSION" ]] && [[ "$FETCHED_VERSION" == "$ACTUAL_VERSION" ]]; then
        # The release found is the one already installed (typically: the pinned tag has no
        # release yet and latest is what we have). Record it instead of downloading it again.
        echo "$FETCHED_VERSION" > "$VERSION_FILE"
        if [[ -n "$DESIRED_VERSION" ]] && [[ "$FETCHED_VERSION" != "$DESIRED_VERSION" ]]; then
            echo "$BINARY_NAME: WARNING — v${DESIRED_VERSION} has no release yet; keeping installed v${FETCHED_VERSION}" >&2
        fi
    else
        if curl -sL --max-time 300 "$URL" -o "${BINARY}.tmp" 2>/dev/null; then
            chmod +x "${BINARY}.tmp"
            mv "${BINARY}.tmp" "$BINARY"
            # #483: record the release actually fetched, not the pin. `unknown` (when the
            # tag cannot be read) never equals a pin, so a later run checks again.
            echo "${FETCHED_VERSION:-unknown}" > "$VERSION_FILE"
            if [[ -n "$DESIRED_VERSION" ]] && [[ "$FETCHED_VERSION" != "$DESIRED_VERSION" ]]; then
                echo "$BINARY_NAME: WARNING — v${DESIRED_VERSION} has no release; installed v${FETCHED_VERSION:-unknown} from releases/latest" >&2
            else
                echo "$BINARY_NAME: installed v${FETCHED_VERSION:-unknown}" >&2
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
fi

exec "$BINARY" "$@"
