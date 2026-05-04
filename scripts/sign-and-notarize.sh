#!/bin/bash
# Sign and notarize the CheICalMCP universal binary for outside-App-Store distribution.
#
# macOS 26 tightened TCC: ad-hoc signed binaries can no longer trigger
# Calendar / Reminders permission grants. Distribution-quality binaries must
# be signed with a Developer ID Application cert + hardened runtime + notarized.
#
# Stapling is NOT performed: stapler staple does not support raw Mach-O
# binaries (only .app/.pkg/.dmg). Gatekeeper online-checks at first launch
# instead — this requires the user's machine to be online once when first
# running the binary.
#
# Usage:
#   scripts/sign-and-notarize.sh <path/to/binary>
#
# Env vars:
#   DEVELOPER_ID    — codesigning identity (default: "Developer ID Application: CHE CHENG (6W377FS7BS)")
#   NOTARY_PROFILE  — notarytool keychain profile name (default: "che-ical-mcp")
#   ENTITLEMENTS    — entitlements .plist path (default: "Sources/CheICalMCP/Entitlements.plist")

set -euo pipefail

BINARY="${1:?Usage: $0 <path/to/binary>}"
DEVELOPER_ID="${DEVELOPER_ID:-Developer ID Application: CHE CHENG (6W377FS7BS)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-che-ical-mcp}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENTITLEMENTS="${ENTITLEMENTS:-$PROJECT_DIR/Sources/CheICalMCP/Entitlements.plist}"

if [[ ! -f "$BINARY" ]]; then
    echo "Error: binary not found at $BINARY" >&2
    exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "Error: entitlements file not found at $ENTITLEMENTS" >&2
    exit 1
fi

echo "=== sign-and-notarize: $BINARY ==="
echo "  Identity:      $DEVELOPER_ID"
echo "  Profile:       $NOTARY_PROFILE"
echo "  Entitlements:  $ENTITLEMENTS"
echo ""

# Step 1: codesign with hardened runtime
echo "[1/4] Signing with Developer ID + hardened runtime..."
codesign --force \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$DEVELOPER_ID" \
    "$BINARY"

# Step 2: verify signature locally
echo ""
echo "[2/4] Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$BINARY" 2>&1 | head -5

# Step 3: notarize (requires zip wrapper for raw Mach-O)
echo ""
echo "[3/4] Submitting for notarization (this typically takes 1-15 minutes)..."
ZIP_PATH="/tmp/$(basename "$BINARY")-notarize.zip"
ditto -c -k --keepParent "$BINARY" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
rm -f "$ZIP_PATH"

# Step 4: print final state for visual confirmation
echo ""
echo "[4/4] Final signature state:"
codesign -dv --verbose=2 "$BINARY" 2>&1 | grep -E "Authority|TeamIdentifier|flags|Signature"

echo ""
echo "=== sign-and-notarize: DONE ==="
echo "Note: stapling skipped (raw Mach-O binaries don't support stapler)."
echo "      Gatekeeper will online-check on first launch."
