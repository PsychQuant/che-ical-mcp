BINARY_NAME := CheICalMCP

# Swift 6 Concurrency Guard:
# Try native build first; fall back to Swift 5 language mode if upstream
# dependencies have strict concurrency errors (swift-sdk#214).
# Remove FALLBACK_FLAGS once the upstream issue is fixed.
FALLBACK_FLAGS := $(shell swift build 2>&1 | grep -q "SendingRisksDataRace" && echo "-Xswiftc -swift-version -Xswiftc 5")

.PHONY: build release release-signed install clean test

build:
	swift build $(FALLBACK_FLAGS)

# Local release build (ad-hoc signed). Use for dev iteration, NOT for distribution.
release:
	swift build -c release $(FALLBACK_FLAGS)

# Distribution release: builds universal binary, signs with Developer ID,
# notarizes via xcrun notarytool, and packages into .mcpb.
# Requires Developer ID Application cert in keychain + notarytool keychain
# profile (see README "Signing & Notarization" for one-time setup).
#
# REQUIRE_CODESIGN=1 makes signing mandatory — missing DEVELOPER_ID, missing
# cert, or missing notarytool profile will fail-fast instead of silently
# producing an unsigned .mcpb. This is the canonical release-cut command;
# use plain `./scripts/build-mcpb.sh` (without the flag) for fork-friendly
# unsigned dev builds.
release-signed:
	@echo "⚠ macOS 26 TCC behavior on the resulting binary remains unverified."
	@echo "  Manual test required before tagging v1.7.1 — see #54."
	@echo ""
	@: $${DEVELOPER_ID:?DEVELOPER_ID not set. See README 'Signing & Notarization' for setup.}
	@: $${NOTARY_PROFILE:?NOTARY_PROFILE not set. See README 'Signing & Notarization' for setup.}
	REQUIRE_CODESIGN=1 ./scripts/build-mcpb.sh

# Local dev install with ad-hoc signing. Fast iteration; macOS ≤ 25 only.
# For testing the actual distributable artifact, use `make release-signed`.
install: release
	cp .build/release/$(BINARY_NAME) ~/bin/$(BINARY_NAME)
	chmod +x ~/bin/$(BINARY_NAME)
	codesign --force --sign - ~/bin/$(BINARY_NAME)
	@echo "Installed: ~/bin/$(BINARY_NAME) (ad-hoc signed — dev only)"

test:
	swift test $(FALLBACK_FLAGS)

clean:
	swift package clean
