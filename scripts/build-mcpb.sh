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

# Co-located Claude Code distribution artifacts (#163 co-locate-plugin-marketplace):
# the self-hosted marketplace entry + the plugin manifest must also match the source
# of truth, or the two channels (Desktop .mcpb / Code self-hosted marketplace) ship
# mismatched versions. Guarded with -f so forks / partial checkouts without the
# co-located plugin still build.
MKTPL_JSON="$PROJECT_DIR/.claude-plugin/marketplace.json"
PLUGIN_MANIFEST="$PROJECT_DIR/plugin/.claude-plugin/plugin.json"

if [[ -f "$MKTPL_JSON" ]]; then
    MKTPL_VERSION=$(python3 -c "import json; d=json.load(open('$MKTPL_JSON')); print(next((p.get('version','') for p in d.get('plugins',[]) if p.get('name')=='che-ical-mcp'), ''))")
    if [[ "$MKTPL_VERSION" != "$SOURCE_VERSION" ]]; then
        echo "  ✗ Version drift: Version.swift=$SOURCE_VERSION but .claude-plugin/marketplace.json che-ical-mcp entry=$MKTPL_VERSION"
        echo "    Bump the che-ical-mcp plugin entry \"version\" in .claude-plugin/marketplace.json to \"$SOURCE_VERSION\"."
        exit 1
    fi
fi

if [[ -f "$PLUGIN_MANIFEST" ]]; then
    PLUGIN_MANIFEST_VERSION=$(python3 -c "import json; print(json.load(open('$PLUGIN_MANIFEST')).get('version',''))")
    if [[ "$PLUGIN_MANIFEST_VERSION" != "$SOURCE_VERSION" ]]; then
        echo "  ✗ Version drift: Version.swift=$SOURCE_VERSION but plugin/.claude-plugin/plugin.json=$PLUGIN_MANIFEST_VERSION"
        echo "    Bump plugin/.claude-plugin/plugin.json \"version\" to \"$SOURCE_VERSION\"."
        exit 1
    fi
fi

echo "  ✓ Version.swift, Info.plist, mcpb/manifest.json, marketplace.json + plugin.json all at $SOURCE_VERSION"

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

# SHA-256 companion file (#98 self-update verification).
# Written next to the binary so `gh release create` can upload both as assets;
# `--self-update` (SelfUpdate.swift) downloads BOTH and verifies before install.
# Format: single-line hex hash (matches `shasum -a 256` / `sha256sum` output).
# We hash the SIGNED + NOTARIZED universal binary, so the .sha256 file
# is generated AFTER signing — see post-Step-6 SHA write below for the
# canonical artifact. This early write covers SKIP_CODESIGN=1 paths so
# unsigned dev builds still get a checksum companion (handy for testing).
SHA256_FILE="${UNIVERSAL_BINARY}.sha256"
shasum -a 256 "$UNIVERSAL_BINARY" | awk '{print $1}' > "$SHA256_FILE"
echo ""
echo "SHA-256: $(cat "$SHA256_FILE")"
echo "  written to: $SHA256_FILE"

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

# Defensive re-check: whenever signing was requested ($SHOULD_SIGN=true), the
# binary at $UNIVERSAL_BINARY MUST now carry a Developer ID Application signature
# from the configured $DEVELOPER_ID. Catches partial-state failures where
# sign-and-notarize.sh exit code was lost (piped to log, CI without pipefail) or
# tampered after sign-and-notarize.sh exit. Refuses to pack a half-signed
# artifact into the .mcpb (cf. #53).
#
# Three layers of strictness, in order:
#   (a) codesign --verify --strict — actual integrity check (not just metadata)
#   (b) Authority binds to the EXACT $DEVELOPER_ID identity (not any random
#       Developer ID team's cert that happened to land in the binary)
#   (c) Authority excludes "Developer ID Installer:" — Mach-O CLI binaries
#       must be signed with the Application cert, not the Installer cert
#
# Gate is $SHOULD_SIGN==true (broader than REQUIRE_CODESIGN) so direct
# `./scripts/build-mcpb.sh` invocations with DEVELOPER_ID set also benefit
# from the post-sign defense — anyone who asked for signing gets verified.
if [[ "$SHOULD_SIGN" == "true" ]]; then
    if ! codesign --verify --strict --verbose=2 "$UNIVERSAL_BINARY" >/dev/null 2>&1; then
        echo ""
        echo "✗ Pre-pack defense: codesign --verify --strict failed for $UNIVERSAL_BINARY" >&2
        echo "  sign-and-notarize.sh likely failed silently or the binary was tampered" >&2
        echo "  after signing. Refusing to pack into .mcpb." >&2
        codesign --verify --strict --verbose=2 "$UNIVERSAL_BINARY" 2>&1 | sed 's/^/  /' >&2
        exit 1
    fi
    # Confirm the signing identity is the one we asked for.
    # DEVELOPER_ID is a SHA-1 cert fingerprint, but `codesign -dv` prints
    # `Authority=<cert CN>` (human-readable), never the SHA — so we reverse-lookup
    # the Team ID from the keychain via `security find-identity` and verify
    # against `TeamIdentifier=` instead. Team ID is the cert's stable unique
    # identifier and avoids hardcoding the CN ("Developer ID Application: ...").
    IDENTITY_LINE=$(security find-identity -p codesigning -v 2>/dev/null | grep -F "$DEVELOPER_ID" | head -1)
    EXPECTED_TEAM_ID=""
    if [[ "$IDENTITY_LINE" =~ \(([A-Z0-9]+)\)\" ]]; then
        EXPECTED_TEAM_ID="${BASH_REMATCH[1]}"
    fi
    if [[ -z "$EXPECTED_TEAM_ID" ]]; then
        echo ""
        echo "✗ Pre-pack defense: cannot derive Team ID from DEVELOPER_ID cert." >&2
        echo "  DEVELOPER_ID=$DEVELOPER_ID not found in keychain or cert CN missing Team ID suffix." >&2
        exit 1
    fi
    if ! codesign -dv --verbose=2 "$UNIVERSAL_BINARY" 2>&1 | grep -qE "^TeamIdentifier=${EXPECTED_TEAM_ID}\$"; then
        echo ""
        echo "✗ Pre-pack defense: $UNIVERSAL_BINARY is not signed by the expected team." >&2
        echo "  Expected: TeamIdentifier=$EXPECTED_TEAM_ID (derived from DEVELOPER_ID $DEVELOPER_ID)" >&2
        echo "  Actual codesign metadata:" >&2
        codesign -dv --verbose=2 "$UNIVERSAL_BINARY" 2>&1 | grep -E "Authority|TeamIdentifier" | sed 's/^/    /' >&2
        exit 1
    fi

    # Re-compute SHA-256 of the signed + notarized binary (#98).
    # The hash from before signing is now stale — codesign embeds the
    # cert chain into the Mach-O Code Signing section, changing the
    # binary's bytes. The .sha256 companion uploaded to the GitHub
    # Release MUST match the binary that --self-update will download
    # post-notarization, so we overwrite it here.
    shasum -a 256 "$UNIVERSAL_BINARY" | awk '{print $1}' > "$SHA256_FILE"
    echo ""
    echo "Post-sign SHA-256: $(cat "$SHA256_FILE")"
    echo "  → upload alongside binary: \`gh release create vX.Y.Z $UNIVERSAL_BINARY $SHA256_FILE ...\`"
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
    # Validate manifest schema before packing (#138) — fail-fast on schema drift
    # (e.g. mcpb 2.1.2 strict-rejects unknown compatibility.runtimes keys) rather
    # than letting `mcpb pack` abort mid-way with a cryptic error. set -e aborts here.
    echo "Validating manifest schema..."
    mcpb validate manifest.json
    # Pack with an explicit, version-stamped output name (#112). `mcpb pack`
    # otherwise derives the output filename from the source dir name → mcpb/mcpb.mcpb,
    # forcing a manual rename every release. .mcpbignore (#111) keeps prior
    # versions' artifacts out of the archive.
    PACKED="che-ical-mcp-${SOURCE_VERSION}.mcpb"
    mcpb pack . "$PACKED"
    shasum -a 256 "$PACKED" | awk '{print $1}' > "${PACKED}.sha256"
    echo ""
    echo "=== Build Complete ==="
    echo "MCPB package: $MCPB_DIR/$PACKED"
    echo "SHA-256:      $MCPB_DIR/${PACKED}.sha256"
else
    echo "=== Build Complete (Manual Pack Required) ==="
    echo "mcpb CLI not found. To pack the bundle:"
    echo "  1. Install: npm install -g @anthropic-ai/mcpb"
    echo "  2. Run: cd mcpb && mcpb pack . \"che-ical-mcp-${SOURCE_VERSION}.mcpb\""
fi

echo ""
echo "Contents of mcpb/:"
ls -la "$MCPB_DIR"
