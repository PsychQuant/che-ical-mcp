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

echo "[1/7] Checking Swift 6 strict concurrency compatibility..."
if swift build -c release --arch arm64 2>&1 | grep -q "SendingRisksDataRace"; then
    echo "  ⚠ Upstream dependency has Swift 6 concurrency errors (swift-sdk#214)"
    echo "  → Falling back to Swift 5 language mode for dependencies"
    SWIFT_FALLBACK_FLAGS=(-Xswiftc -swift-version -Xswiftc 5)
else
    echo "  ✓ Swift 6 strict concurrency OK"
fi

# Step 2: Version consistency check.
# AppVersion.current (Sources/CheICalMCP/Version.swift) is the source of truth.
# mcpb/manifest.json and Info.plist MUST match. server.json is independent — see
# README "Release Process" — because it's a Registry snapshot that bumps only
# when re-submitting the .mcpb bundle to MCP Registry.
echo "[2/7] Checking version consistency..."
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

# Steps 3-4: Build for both architectures
echo "[3/7] Building for Apple Silicon (arm64)..."
cd "$PROJECT_DIR"
swift build -c release --arch arm64 "${SWIFT_FALLBACK_FLAGS[@]}"

echo "[4/7] Building for Intel (x86_64)..."
swift build -c release --arch x86_64 "${SWIFT_FALLBACK_FLAGS[@]}"

# Step 5: Create Universal Binary
echo "[5/7] Creating Universal Binary..."
mkdir -p "$SERVER_DIR"

ARM64_BINARY="$PROJECT_DIR/.build/arm64-apple-macosx/release/CheICalMCP"
X64_BINARY="$PROJECT_DIR/.build/x86_64-apple-macosx/release/CheICalMCP"
UNIVERSAL_BINARY="$SERVER_DIR/CheICalMCP"

if [[ -f "$ARM64_BINARY" && -f "$X64_BINARY" ]]; then
    # rm -f forces fresh inode (see Makefile install: target for the rationale —
    # macOS kernel caches code-signature hashes per-inode, and reusing an inode
    # held open by an old running CheICalMCP process triggers SIGKILL with
    # "load code signature error 2" on subsequent execs. See #62.)
    rm -f "$UNIVERSAL_BINARY"
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

# Step 6: Sign + notarize for distribution.
# Required for releases: macOS 26 TCC rejects ad-hoc binaries; Developer ID
# signing + hardened runtime + notarization is the only way Calendar/Reminders
# permission dialogs appear for end users.
#
# Behavior:
#   SKIP_CODESIGN=1 (or "true") → skip unconditionally (local iteration override)
#   REQUIRE_CODESIGN=1 → fail-fast if signing prerequisites missing
#     (used by `make release-signed` — canonical release path must not
#      silently produce unsigned artifacts)
#   No DEVELOPER_ID env or no cert in keychain → auto-skip with warning
#     (default fork-friendly behavior for direct `./scripts/build-mcpb.sh`)
#   Otherwise → run sign-and-notarize.sh
echo ""
SHOULD_SIGN=true
SKIP_REASON=""
if [[ "${SKIP_CODESIGN:-}" == "1" || "${SKIP_CODESIGN:-}" == "true" ]]; then
    SHOULD_SIGN=false
    SKIP_REASON="SKIP_CODESIGN=$SKIP_CODESIGN"
elif [[ -z "${DEVELOPER_ID:-}" ]]; then
    SHOULD_SIGN=false
    SKIP_REASON="DEVELOPER_ID env not set"
elif ! security find-identity -p codesigning -v 2>/dev/null | grep -qF "$DEVELOPER_ID"; then
    SHOULD_SIGN=false
    SKIP_REASON="codesigning identity '$DEVELOPER_ID' not in keychain"
fi

if [[ "$SHOULD_SIGN" == "false" ]]; then
    if [[ "${REQUIRE_CODESIGN:-}" == "1" || "${REQUIRE_CODESIGN:-}" == "true" ]]; then
        # Canonical release path — refuse to produce unsigned artifact silently
        echo "[6/7] ✗ Refusing to skip signing: REQUIRE_CODESIGN=$REQUIRE_CODESIGN" >&2
        echo "        Reason: $SKIP_REASON" >&2
        echo "        Fix: set DEVELOPER_ID + NOTARY_PROFILE, install Developer ID Application" >&2
        echo "             cert, and ensure cert is in your login keychain." >&2
        echo "        See README 'Signing & Notarization' for one-time setup." >&2
        exit 1
    fi
    # Fork-friendly auto-skip: warn + continue with unsigned binary
    echo "[6/7] Skipping codesign + notarize."
    echo "  Reason: $SKIP_REASON"
    echo "  ⚠ Resulting binary is ad-hoc signed; suitable for local dev only."
    echo "  ⚠ To produce a release-quality .mcpb on macOS 26: set DEVELOPER_ID + NOTARY_PROFILE,"
    echo "    install Developer ID Application cert, then run \`make release-signed\`."
else
    echo "[6/7] Signing + notarizing for distribution..."
    "$SCRIPT_DIR/sign-and-notarize.sh" "$UNIVERSAL_BINARY"
fi

# Defensive re-check: when REQUIRE_CODESIGN forced signing, the binary at
# $UNIVERSAL_BINARY MUST now be Developer-ID-signed. This catches the case
# where sign-and-notarize.sh exit code was lost (e.g. piped to a log without
# pipefail in calling environment) — refuses to pack a half-signed artifact
# into the .mcpb (cf. #53).
if [[ "${REQUIRE_CODESIGN:-}" == "1" || "${REQUIRE_CODESIGN:-}" == "true" ]]; then
    if ! codesign -dv --verbose=2 "$UNIVERSAL_BINARY" 2>&1 | grep -q "Authority=Developer ID"; then
        echo ""
        echo "[7/7] ✗ REQUIRE_CODESIGN was set but $UNIVERSAL_BINARY is NOT Developer-ID-signed." >&2
        echo "        sign-and-notarize.sh likely failed silently — refusing to pack" >&2
        echo "        an unsigned/ad-hoc artifact into the .mcpb." >&2
        codesign -dv --verbose=2 "$UNIVERSAL_BINARY" 2>&1 | sed 's/^/        /' >&2
        exit 1
    fi
fi

# Step 7: Check for required files
echo ""
echo "[7/7] Checking MCPB package contents..."

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

# Final: Pack MCPB (if mcpb CLI is available)
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
