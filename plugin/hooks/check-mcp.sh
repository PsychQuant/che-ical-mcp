#!/bin/bash
# Auto-install and update check for che-ical-mcp

BINARY_NAME="CheICalMCP"
INSTALL_PATH="$HOME/bin/$BINARY_NAME"
GITHUB_REPO="PsychQuant/che-ical-mcp"
RELEASE_URL="https://github.com/$GITHUB_REPO/releases/latest/download/$BINARY_NAME"

# Possible installation locations
LOCATIONS=(
    "$HOME/bin/$BINARY_NAME"
    "/usr/local/bin/che-ical-mcp"
    "/usr/local/bin/$BINARY_NAME"
    "$HOME/.local/bin/$BINARY_NAME"
)

MCP_FOUND=false
MCP_PATH=""

# Check for existing installation
for loc in "${LOCATIONS[@]}"; do
    if [[ -x "$loc" ]]; then
        MCP_FOUND=true
        MCP_PATH="$loc"
        break
    fi
done

# Function to get latest version from GitHub
get_latest_version() {
    curl -sI "https://github.com/$GITHUB_REPO/releases/latest" 2>/dev/null | \
        grep -i "^location:" | \
        sed -E 's|.*/v?([0-9]+\.[0-9]+\.[0-9]+).*|\1|' | \
        tr -d '\r\n'
}

# Function to install binary
install_binary() {
    echo "📦 Installing $BINARY_NAME..."
    mkdir -p "$HOME/bin"

    if curl -fsSL "$RELEASE_URL" -o "$INSTALL_PATH" 2>/dev/null; then
        chmod +x "$INSTALL_PATH"
        echo "✅ Installed $BINARY_NAME to $INSTALL_PATH"

        # Register with Claude if not already
        if command -v claude &> /dev/null; then
            if ! claude mcp list 2>/dev/null | grep -q "che-ical-mcp"; then
                claude mcp add --scope user che-ical-mcp -- "$INSTALL_PATH" 2>/dev/null || true
                echo "✅ Registered with Claude Code"
            fi
        fi
        return 0
    else
        echo "❌ Failed to download $BINARY_NAME"
        echo "   Manual install: $RELEASE_URL"
        return 1
    fi
}

if [[ "$MCP_FOUND" == "true" ]]; then
    # Get installed version
    INSTALLED_VERSION=$(timeout 2 "$MCP_PATH" --version 2>/dev/null | awk '{print $NF}' || true)

    # Get latest version
    LATEST_VERSION=$(get_latest_version)

    if [[ -n "$INSTALLED_VERSION" && -n "$LATEST_VERSION" ]]; then
        if [[ "$INSTALLED_VERSION" != "$LATEST_VERSION" ]]; then
            echo "⬆️  che-ical-mcp v$INSTALLED_VERSION → v$LATEST_VERSION available"
            echo "   Update: curl -fsSL $RELEASE_URL -o $MCP_PATH && chmod +x $MCP_PATH"
        else
            echo "✓ che-ical-mcp v$INSTALLED_VERSION (latest)"
        fi
    elif [[ -n "$INSTALLED_VERSION" ]]; then
        echo "✓ che-ical-mcp v$INSTALLED_VERSION installed"
    else
        echo "✓ che-ical-mcp installed: $MCP_PATH"
    fi
else
    # Check if registered via claude mcp (might be using different path)
    if command -v claude &> /dev/null; then
        if claude mcp list 2>/dev/null | grep -q "che-ical-mcp"; then
            echo "✓ che-ical-mcp registered (via claude mcp)"
            exit 0
        fi
    fi

    # Not found - auto install
    echo "⚠️  che-ical-mcp not found - installing automatically..."
    install_binary
fi

# Current time context (always output for temporal awareness)
NOW_ISO=$(date '+%Y-%m-%dT%H:%M:%S%z')
NOW_WEEKDAY_NUM=$(date "+%u")
NOW_EN=$(LANG=en_US.UTF-8 date "+%A")
case "$NOW_WEEKDAY_NUM" in
    1) NOW_ZH="週一" ;; 2) NOW_ZH="週二" ;; 3) NOW_ZH="週三" ;;
    4) NOW_ZH="週四" ;; 5) NOW_ZH="週五" ;; 6) NOW_ZH="週六" ;;
    7) NOW_ZH="週日" ;; *) NOW_ZH="" ;;
esac
case "$NOW_WEEKDAY_NUM" in
    1) NOW_JA="月曜日" ;; 2) NOW_JA="火曜日" ;; 3) NOW_JA="水曜日" ;;
    4) NOW_JA="木曜日" ;; 5) NOW_JA="金曜日" ;; 6) NOW_JA="土曜日" ;;
    7) NOW_JA="日曜日" ;; *) NOW_JA="" ;;
esac
LOCALE="${LANG:-en_US.UTF-8}"
case "$LOCALE" in
    zh_TW*|zh_HK*) echo "🕐 現在: ${NOW_ISO} ${NOW_ZH} (${NOW_EN})" ;;
    zh_CN*)        echo "🕐 现在: ${NOW_ISO} ${NOW_ZH} (${NOW_EN})" ;;
    ja_JP*)        echo "🕐 現在: ${NOW_ISO} ${NOW_JA} (${NOW_EN})" ;;
    *)             echo "🕐 Now: ${NOW_ISO} ${NOW_EN} (${NOW_ZH})" ;;
esac
