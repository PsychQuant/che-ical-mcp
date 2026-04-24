#!/bin/bash
# Build script for che-ical-mcp MCPB package
# Creates a Universal Binary and packages it for Claude Desktop

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
MCPB_DIR="$PROJECT_DIR/mcpb"
SERVER_DIR="$MCPB_DIR/server"

echo "=== che-ical-mcp MCPB Build Script ==="
echo "Project directory: $PROJECT_DIR"
echo ""

# Swift 6 Concurrency Guard
# Try Swift 6 (strict concurrency) first; if upstream dependencies fail,
# fall back to Swift 5 language mode. Remove fallback once
# modelcontextprotocol/swift-sdk#214 is fixed.
SWIFT_FALLBACK_FLAGS=()

echo "[0/5] Checking Swift 6 strict concurrency compatibility..."
if swift build -c release --arch arm64 2>&1 | grep -q "SendingRisksDataRace"; then
    echo "  ⚠ Upstream dependency has Swift 6 concurrency errors (swift-sdk#214)"
    echo "  → Falling back to Swift 5 language mode for dependencies"
    SWIFT_FALLBACK_FLAGS=(-Xswiftc -swift-version -Xswiftc 5)
else
    echo "  ✓ Swift 6 strict concurrency OK"
fi

# Step 0.5: Version consistency check.
# AppVersion.current (Sources/CheICalMCP/Version.swift) is the source of truth.
# mcpb/manifest.json and Info.plist MUST match. server.json is independent — see
# README "Release Process" — because it's a Registry snapshot that bumps only
# when re-submitting the .mcpb bundle to MCP Registry.
echo "[0.5/5] Checking version consistency..."
VERSION_SWIFT="$PROJECT_DIR/Sources/CheICalMCP/Version.swift"
MCPB_MANIFEST="$MCPB_DIR/manifest.json"
INFO_PLIST="$PROJECT_DIR/Sources/CheICalMCP/Info.plist"

SOURCE_VERSION=$(grep -E 'static let current = "' "$VERSION_SWIFT" | sed -E 's/.*"([^"]+)".*/\1/')
MCPB_VERSION=$(grep -E '"version"' "$MCPB_MANIFEST" | head -1 | sed -E 's/.*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/')
PLIST_VERSION=$(awk '/<key>CFBundleVersion<\/key>/{getline; print}' "$INFO_PLIST" | sed -E 's/.*<string>([^<]+)<\/string>.*/\1/')

if [[ -z "$SOURCE_VERSION" ]]; then
    echo "  ✗ Failed to parse AppVersion.current from Version.swift"
    exit 1
fi

if [[ "$MCPB_VERSION" != "$SOURCE_VERSION" ]]; then
    echo "  ✗ Version drift: Version.swift=$SOURCE_VERSION but mcpb/manifest.json=$MCPB_VERSION"
    echo "    Bump mcpb/manifest.json \"version\" to \"$SOURCE_VERSION\" before building."
    exit 1
fi

if [[ "$PLIST_VERSION" != "$SOURCE_VERSION" ]]; then
    echo "  ✗ Version drift: Version.swift=$SOURCE_VERSION but Info.plist CFBundleVersion=$PLIST_VERSION"
    echo "    Bump Sources/CheICalMCP/Info.plist CFBundleVersion to \"$SOURCE_VERSION\" before building."
    exit 1
fi

echo "  ✓ Version.swift, Info.plist, and mcpb/manifest.json all at $SOURCE_VERSION"

# Step 1: Build for both architectures
echo "[1/4] Building for Apple Silicon (arm64)..."
cd "$PROJECT_DIR"
swift build -c release --arch arm64 "${SWIFT_FALLBACK_FLAGS[@]}"

echo "[2/4] Building for Intel (x86_64)..."
swift build -c release --arch x86_64 "${SWIFT_FALLBACK_FLAGS[@]}"

# Step 2: Create Universal Binary
echo "[3/4] Creating Universal Binary..."
mkdir -p "$SERVER_DIR"

ARM64_BINARY="$PROJECT_DIR/.build/arm64-apple-macosx/release/CheICalMCP"
X64_BINARY="$PROJECT_DIR/.build/x86_64-apple-macosx/release/CheICalMCP"
UNIVERSAL_BINARY="$SERVER_DIR/CheICalMCP"

if [[ -f "$ARM64_BINARY" && -f "$X64_BINARY" ]]; then
    lipo -create "$ARM64_BINARY" "$X64_BINARY" -output "$UNIVERSAL_BINARY"
    chmod +x "$UNIVERSAL_BINARY"
    echo "Created Universal Binary: $UNIVERSAL_BINARY"
else
    echo "Error: Could not find architecture-specific binaries"
    echo "  ARM64: $ARM64_BINARY (exists: $(test -f "$ARM64_BINARY" && echo yes || echo no))"
    echo "  X64: $X64_BINARY (exists: $(test -f "$X64_BINARY" && echo yes || echo no))"
    exit 1
fi

# Verify Universal Binary
echo ""
echo "Binary info:"
file "$UNIVERSAL_BINARY"
echo ""
echo "Architectures:"
lipo -info "$UNIVERSAL_BINARY"

# Step 3: Check for required files
echo ""
echo "[4/4] Checking MCPB package contents..."

REQUIRED_FILES=(
    "$MCPB_DIR/manifest.json"
    "$MCPB_DIR/PRIVACY.md"
    "$SERVER_DIR/CheICalMCP"
)

MISSING=0
for f in "${REQUIRED_FILES[@]}"; do
    if [[ -f "$f" ]]; then
        echo "  ✓ $(basename "$f")"
    else
        echo "  ✗ $(basename "$f") - MISSING"
        MISSING=1
    fi
done

# Check for icon (optional but recommended)
if [[ -f "$MCPB_DIR/icon.png" ]]; then
    echo "  ✓ icon.png"
else
    echo "  ⚠ icon.png - MISSING (optional but recommended for submission)"
fi

if [[ $MISSING -eq 1 ]]; then
    echo ""
    echo "Error: Missing required files. Please create them before packaging."
    exit 1
fi

# Step 4: Pack MCPB (if mcpb CLI is available)
echo ""
if command -v mcpb &> /dev/null; then
    echo "Packing MCPB bundle..."
    cd "$MCPB_DIR"
    mcpb pack
    echo ""
    echo "=== Build Complete ==="
    echo "MCPB package: $MCPB_DIR/che-ical-mcp.mcpb"
else
    echo "=== Build Complete (Manual Pack Required) ==="
    echo "mcpb CLI not found. To pack the bundle:"
    echo "  1. Install: npm install -g @anthropic-ai/mcpb"
    echo "  2. Run: cd mcpb && mcpb pack"
fi

echo ""
echo "Contents of mcpb/:"
ls -la "$MCPB_DIR"
