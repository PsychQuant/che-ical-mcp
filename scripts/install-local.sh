#!/bin/bash
# install-local.sh <adhoc|developer-id> [swift build flags...] — the step behind
# `make install` and `make install-signed` (#239).
#
# It installs a product it built and checked in the same run. Under the swiftbuild build
# system .build/release points at a directory every `swift build --arch` run writes to
# (build-mcpb.sh writes an x86_64-only product there last), so copying that fixed path
# could install the wrong architecture with no error. Instead, like build-mcpb.sh (#238):
#   1. build for the host architecture (`uname -m`; under Rosetta that is x86_64, the
#      architecture this shell runs);
#   2. take the product from `swift build --show-bin-path` of the same command;
#   3. copy it to a stage file and run check_staged_product on it (exactly the host
#      architecture, `--version` equal to AppVersion.current in Version.swift);
#   4. only then replace the installed file: rm -f first, for a fresh inode (#62), then
#      copy and sign; the signed file is checked once more.
# A refused product leaves the installed file as it was.
#
# INSTALL_DIR (default ~/bin) chooses where it goes, so the step can be tested without
# replacing the maintainer's binary. SWIFT (default swift) is the build command; the test
# replaces it with a stub. developer-id signing needs DEVELOPER_ID.
set -euo pipefail

MODE="${1:-}"
shift || true
case "$MODE" in
    adhoc|developer-id) ;;
    *) echo "usage: $0 <adhoc|developer-id> [swift build flags...]" >&2; exit 2 ;;
esac

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/check-staged-product.sh
source "$PROJECT_DIR/scripts/lib/check-staged-product.sh"

NAME=CheICalMCP
SWIFT="${SWIFT:-swift}"
INSTALL_DIR="${INSTALL_DIR:-$HOME/bin}"
ARCH=$(uname -m)
VERSION=$(grep -E 'static let current = "' "$PROJECT_DIR/Sources/CheICalMCP/Version.swift" | sed -E 's/.*"([^"]+)".*/\1/')
if [[ -z "$VERSION" ]]; then
    echo "Error: cannot read AppVersion.current from Version.swift (#239)" >&2
    exit 1
fi
if [[ "$MODE" == developer-id && -z "${DEVELOPER_ID:-}" ]]; then
    echo "Error: DEVELOPER_ID not set. See README 'Signing & Notarization' for setup." >&2
    exit 1
fi
# The host can always run its own architecture, so the version check is never skipped.
export CHECK_STAGED_STRICT=1

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

DEST="$INSTALL_DIR/$NAME"
mkdir -p "$INSTALL_DIR"
rm -f "$DEST"
cp "$STAGED" "$DEST"
chmod +x "$DEST"
if [[ "$MODE" == adhoc ]]; then
    codesign --force --sign - "$DEST"
else
    codesign --force --sign "$DEVELOPER_ID" --options runtime \
             --entitlements "$PROJECT_DIR/Sources/CheICalMCP/Entitlements.plist" "$DEST"
fi
check_staged_product "$DEST" "$ARCH" "$NAME" "$VERSION" || exit 1
