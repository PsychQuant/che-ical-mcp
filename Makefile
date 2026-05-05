BINARY_NAME := CheICalMCP

# Swift 6 Concurrency Guard:
# Try native build first; fall back to Swift 5 language mode if upstream
# dependencies have strict concurrency errors (swift-sdk#214).
# Remove FALLBACK_FLAGS once the upstream issue is fixed.
FALLBACK_FLAGS := $(shell swift build 2>&1 | grep -q "SendingRisksDataRace" && echo "-Xswiftc -swift-version -Xswiftc 5")

.PHONY: build release release-signed verify-release-ready install clean test

# Detect drift between AppVersion.current and the latest release tag.
# AppVersion.current ahead of git tag = unreleased work-in-progress (warning).
# AppVersion.current behind git tag = downgrade or merge mistake (error).
# Equal = ready to tag without a version bump (informational).
#
# This is a soft pre-flight: release-signed depends on it (warns only,
# never aborts), so a maintainer doing genuine pre-release work isn't
# blocked. Surfaces the case where Info.plist / mcpb/manifest.json got
# bumped on main without ever cutting a tag (cf. #48).
verify-release-ready:
	@SOURCE_VERSION=$$(grep -E 'static let current = "' Sources/CheICalMCP/Version.swift | sed -E 's/.*"([^"]+)".*/\1/'); \
	LATEST_TAG=$$(git tag --sort=-creatordate | head -1); \
	if [ -z "$$SOURCE_VERSION" ]; then \
	    echo "✗ Could not parse AppVersion.current from Version.swift" >&2; \
	    exit 1; \
	fi; \
	if [ -z "$$LATEST_TAG" ]; then \
	    echo "ℹ No git tags yet — version drift check skipped (first release?)"; \
	elif [ "v$${SOURCE_VERSION}" = "$$LATEST_TAG" ]; then \
	    echo "ℹ AppVersion.current ($$SOURCE_VERSION) matches latest tag ($$LATEST_TAG) — no version bump needed for next release"; \
	else \
	    echo "⚠ Version drift: AppVersion.current=$$SOURCE_VERSION, latest tag=$$LATEST_TAG"; \
	    echo "  Either tag v$${SOURCE_VERSION} now, or revert the version bump if it was premature."; \
	fi

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
# Must be run from the repo root: this target invokes ./scripts/build-mcpb.sh
# via a relative path. `make -f /abs/path/Makefile release-signed` from a
# different cwd would fail to find the script.
release-signed: verify-release-ready
	@echo ""
	@echo "⚠ macOS 26 TCC behavior on the resulting binary remains unverified."
	@echo "  Manual test required before tagging v1.7.1 — see #54."
	@echo ""
	@: $${DEVELOPER_ID:?DEVELOPER_ID not set. See README 'Signing & Notarization' for setup.}
	@: $${NOTARY_PROFILE:?NOTARY_PROFILE not set. See README 'Signing & Notarization' for setup.}
	REQUIRE_CODESIGN=1 ./scripts/build-mcpb.sh

# Local dev install with ad-hoc signing. Fast iteration.
# Note: TCC dialogs do not appear on macOS 26 with ad-hoc signing —
#       use `make release-signed` for testing TCC flows on macOS 26.
#
# rm -f forces a fresh inode: if any old CheICalMCP processes are still running
# (e.g. held by Claude Code MCP integrations or launchd), `cp` over the existing
# file would reuse the same inode, and the macOS kernel caches code-signature
# hashes per-inode — leading to "load code signature error 2" SIGKILL on the
# new binary. See #62 for the upgrade-trap discovery during macOS 26 testing.
install: release
	rm -f ~/bin/$(BINARY_NAME)
	cp .build/release/$(BINARY_NAME) ~/bin/$(BINARY_NAME)
	chmod +x ~/bin/$(BINARY_NAME)
	codesign --force --sign - ~/bin/$(BINARY_NAME)
	@echo "Installed: ~/bin/$(BINARY_NAME) (ad-hoc signed — dev only)"

test:
	swift test $(FALLBACK_FLAGS)

clean:
	swift package clean
