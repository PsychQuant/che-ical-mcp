#!/bin/bash
# install-local.sh <adhoc|developer-id> <install dir> [swift build flags...] — the step behind
# `make install` and `make install-signed` (#239).
#
# It installs a product it built and checked in the same run. Under the swiftbuild build
# system .build/release points at a directory every `swift build --arch` run writes to
# (build-mcpb.sh writes an x86_64-only product there last), so copying that fixed path
# could install the wrong architecture with no error. Instead, like build-mcpb.sh (#238):
#   1. developer-id only: the identity in DEVELOPER_ID must be in the keychain, checked
#      before anything is built (csp_decide_signing);
#   2. build for the host architecture (`uname -m`; under Rosetta that is x86_64, the
#      architecture this shell runs);
#   3. take the product from `swift build --show-bin-path` of the same command;
#   4. copy it to a stage file and run check_staged_product on it (exactly the host
#      architecture, `--version` equal to AppVersion.current in Version.swift);
#   5. sign the STAGED file, verify the signature (`codesign --verify --strict`; for
#      developer-id also the TeamIdentifier of that identity) and run the check again;
#   6. only then replace the installed file: rm -f first, for a fresh inode (#62), then copy.
# Any refusal, including a failed signing or post-sign check, leaves the installed file as
# it was (#239 verify).
#
# The install directory is an argument, not an environment variable, so an exported
# INSTALL_DIR cannot redirect it; a relative one is read against the caller's directory.
# CHE_ICAL_SWIFT and CHE_ICAL_CODESIGN (defaults: swift, /usr/bin/codesign) replace the
# build and signing commands; they exist for scripts/tests/install-local-test.sh. The
# signature is always verified with /usr/bin/codesign.
set -euo pipefail

MODE="${1:-}"
DIR="${2:-}"
case "$MODE" in
    adhoc|developer-id) ;;
    *) echo "usage: $0 <adhoc|developer-id> <install dir> [swift build flags...]" >&2; exit 2 ;;
esac
if [[ -z "$DIR" ]]; then
    echo "usage: $0 <adhoc|developer-id> <install dir> [swift build flags...]" >&2
    exit 2
fi
shift 2
case "$DIR" in
    /*) ;;
    *) DIR="$PWD/$DIR" ;;
esac

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/check-staged-product.sh
source "$PROJECT_DIR/scripts/lib/check-staged-product.sh"

NAME=CheICalMCP
SWIFT="${CHE_ICAL_SWIFT:-swift}"
CODESIGN="${CHE_ICAL_CODESIGN:-/usr/bin/codesign}"
VERIFY_CODESIGN=/usr/bin/codesign
ARCH=$(uname -m)
VERSION=$( { grep -E 'static let current = "' "$PROJECT_DIR/Sources/CheICalMCP/Version.swift" || true; } \
           | sed -E 's/.*"([^"]+)".*/\1/')
if [[ -z "$VERSION" ]]; then
    echo "Error: cannot read AppVersion.current from Version.swift (#239)" >&2
    exit 1
fi

TEAM_ID=""
if [[ "$MODE" == developer-id ]]; then
    if [[ -z "${DEVELOPER_ID:-}" ]]; then
        echo "Error: DEVELOPER_ID not set. See README 'Signing & Notarization' for setup." >&2
        exit 1
    fi
    csp_decide_signing
    if [[ "$SHOULD_SIGN" != true ]]; then
        echo "Error: cannot sign with Developer ID: $SKIP_REASON (#239)" >&2
        exit 1
    fi
    # The team is the last "(XXXXXXXXXX)" on the keychain line that names this identity.
    TEAM_ID=$( { _csp_codesigning_identities | "$CSP_GREP" -F -- "$DEVELOPER_ID" || true; } | head -1 \
               | sed -nE 's/.*\(([A-Z0-9]{10})\)"?[[:space:]]*$/\1/p')
    if [[ -z "$TEAM_ID" ]]; then
        echo "Error: cannot read the team of identity '$DEVELOPER_ID' from the keychain (#239)" >&2
        exit 1
    fi
fi
# The host can always run its own architecture, so the version check is never skipped.
export CHECK_STAGED_STRICT=1

DEST="$DIR/$NAME"
echo "Installing $NAME $VERSION ($ARCH, $MODE) to $DEST"

cd "$PROJECT_DIR"
"$SWIFT" build -c release --arch "$ARCH" "$@"
BIN_DIR=$("$SWIFT" build -c release --arch "$ARCH" --show-bin-path "$@")

STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/che-ical-install.XXXXXX")
trap 'rm -rf "$STAGE_DIR"' EXIT
STAGED="$STAGE_DIR/$NAME"
if [[ -f "$BIN_DIR/$NAME" ]]; then
    cp "$BIN_DIR/$NAME" "$STAGED"
fi
check_staged_product "$STAGED" "$ARCH" "$NAME" "$VERSION" || exit 1

if [[ "$MODE" == adhoc ]]; then
    "$CODESIGN" --force --sign - "$STAGED" || { echo "Error: ad-hoc signing failed; nothing installed (#239)" >&2; exit 1; }
else
    "$CODESIGN" --force --sign "$DEVELOPER_ID" --options runtime \
                --entitlements "$PROJECT_DIR/Sources/CheICalMCP/Entitlements.plist" "$STAGED" \
        || { echo "Error: Developer ID signing failed; nothing installed (#239)" >&2; exit 1; }
fi
if ! "$VERIFY_CODESIGN" --verify --strict "$STAGED" 2>/dev/null; then
    echo "Error: the signed product does not verify (codesign --verify --strict); nothing installed (#239)" >&2
    exit 1
fi
SIGNATURE=$("$VERIFY_CODESIGN" -dv "$STAGED" 2>&1 || true)
if [[ "$MODE" == adhoc ]]; then
    if [[ "$SIGNATURE" != *"Signature=adhoc"* || "$SIGNATURE" == *"linker-signed"* ]]; then
        echo "Error: the product is not ad-hoc signed by codesign; nothing installed (#239)" >&2
        exit 1
    fi
elif [[ "$SIGNATURE" != *"TeamIdentifier=$TEAM_ID"* ]]; then
    echo "Error: the signed product's TeamIdentifier is not $TEAM_ID; nothing installed (#239)" >&2
    exit 1
fi
check_staged_product "$STAGED" "$ARCH" "$NAME" "$VERSION" || exit 1

mkdir -p "$DIR"
rm -f "$DEST"
cp "$STAGED" "$DEST"
