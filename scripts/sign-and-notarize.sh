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
# Required env vars (no defaults — fork-friendly, no maintainer PII in error messages):
#   DEVELOPER_ID    — codesigning identity, e.g. "Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE  — notarytool keychain profile name (set up via: xcrun notarytool store-credentials <name> ...)
#
# Optional env var:
#   ENTITLEMENTS    — entitlements .plist path (default: "Sources/CheICalMCP/Entitlements.plist")

set -euo pipefail

BINARY="${1:?Usage: $0 <path/to/binary>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ENTITLEMENTS="${ENTITLEMENTS:-$PROJECT_DIR/Sources/CheICalMCP/Entitlements.plist}"

# Pre-flight: required env vars
if [[ -z "${DEVELOPER_ID:-}" ]]; then
    echo "Error: DEVELOPER_ID is not set." >&2
    echo "       Export your Developer ID Application identity:" >&2
    echo "       export DEVELOPER_ID='Developer ID Application: Your Name (TEAMID)'" >&2
    echo "       Find available identities: security find-identity -p codesigning -v" >&2
    exit 1
fi

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "Error: NOTARY_PROFILE is not set." >&2
    echo "       Export your notarytool keychain profile name:" >&2
    echo "       export NOTARY_PROFILE='your-profile-name'" >&2
    echo "       Set up profile (one-time): xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team-id>" >&2
    echo "       (notarytool will prompt for app-specific password — do NOT pass it on the command line)" >&2
    exit 1
fi

if [[ ! -f "$BINARY" ]]; then
    echo "Error: binary not found at $BINARY" >&2
    exit 1
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
    echo "Error: entitlements file not found at $ENTITLEMENTS" >&2
    exit 1
fi

# Pre-flight: verify cert exists in keychain (avoids cryptic codesign error mid-flow)
if ! security find-identity -p codesigning -v 2>/dev/null | grep -qF "$DEVELOPER_ID"; then
    echo "Error: codesigning identity not found in keychain: $DEVELOPER_ID" >&2
    echo "       Available identities:" >&2
    security find-identity -p codesigning -v 2>&1 | grep -E '"[^"]*"' | sed 's/^/         /' >&2
    exit 1
fi

# Pre-flight: verify notarytool keychain profile exists (avoids submit-then-fail)
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    echo "Error: notarytool keychain profile '$NOTARY_PROFILE' not configured." >&2
    echo "       Set up with: xcrun notarytool store-credentials $NOTARY_PROFILE \\" >&2
    echo "                      --apple-id <your-apple-id> --team-id <your-team-id>" >&2
    exit 1
fi

# Use mktemp for /tmp zip + trap to ensure cleanup on any exit (including SIGINT/SIGTERM/error)
ZIP_PATH=""
cleanup() {
    [[ -n "$ZIP_PATH" && -f "$ZIP_PATH" ]] && rm -f "$ZIP_PATH"
}
trap cleanup EXIT INT TERM

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
# Note: this is a gating verify (codesign --verify exit code is checked); the |head -5
# is for output trimming only. Under set -o pipefail, if codesign verify fails it will
# write to stderr and exit non-zero, propagating up because head reads <= 5 lines and
# closes its stdin → codesign gets SIGPIPE → pipeline exit non-zero → set -e aborts.
echo ""
echo "[2/4] Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$BINARY" 2>&1 | head -5

# Step 3: notarize (requires zip wrapper for raw Mach-O)
# Capture submission output so we can extract submission ID for post-mortem debug
# if the wait fails. notarytool prints "  id: <UUID>" line on success and failure.
echo ""
echo "[3/4] Submitting for notarization (this typically takes 1-15 minutes)..."
ZIP_PATH="$(mktemp -t notarize-XXXXXXXX).zip"
ditto -c -k --keepParent "$BINARY" "$ZIP_PATH"

# tee output so user sees progress while we capture submission ID
SUBMIT_LOG="$(mktemp -t notarize-log-XXXXXXXX)"
trap 'cleanup; rm -f "$SUBMIT_LOG"' EXIT INT TERM

# Helper: extract submission UUID from notarytool log; never aborts under set -e
# (grep returns 1 if no match → would abort; trailing || true makes it fail-soft)
extract_submission_id() {
    grep -m1 -E '^[[:space:]]*id:' "$1" 2>/dev/null | awk '{print $2}' || true
}

if ! xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait 2>&1 | tee "$SUBMIT_LOG"; then
    SUBMISSION_ID="$(extract_submission_id "$SUBMIT_LOG")"
    echo "" >&2
    echo "Error: notarization failed (or notarytool errored)." >&2
    if [[ -n "$SUBMISSION_ID" ]]; then
        echo "       To see Apple's rejection reason:" >&2
        echo "         xcrun notarytool log $SUBMISSION_ID --keychain-profile $NOTARY_PROFILE" >&2
    else
        echo "       (no submission ID captured — full notarytool output above; if format changed," >&2
        echo "        run: xcrun notarytool history --keychain-profile $NOTARY_PROFILE)" >&2
    fi
    exit 1
fi

SUBMISSION_ID="$(extract_submission_id "$SUBMIT_LOG")"
if [[ -n "$SUBMISSION_ID" ]]; then
    echo "Submission ID: $SUBMISSION_ID"
else
    echo "(submission accepted but ID not captured — notarytool output format may have changed)"
fi

# Step 4: print final state for visual confirmation
# || true: this is informational only; if codesign output format changes and grep
# doesn't match, we don't want to fail the whole script.
echo ""
echo "[4/4] Final signature state:"
codesign -dv --verbose=2 "$BINARY" 2>&1 | grep -E "Authority|TeamIdentifier|flags|Signature" || true

echo ""
echo "=== sign-and-notarize: DONE ==="
echo "Note: stapling skipped (raw Mach-O binaries don't support stapler)."
echo "      Gatekeeper will online-check on first launch."
echo "      To verify notarization end-to-end: spctl -a -vvv -t install $BINARY"
