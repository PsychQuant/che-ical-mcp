#!/bin/bash
# Tests for the `verify-release-ready` Makefile target (#310).
#
# The target compares AppVersion.current with the latest *release* tag. It used to
# take the newest tag of any name, so the `idd-N-verified` tags that the issue
# workflow creates on every issue were read as "the latest tag". Each case builds a
# throwaway git repository with its own tags and a minimal Version.swift, then runs
# the real Makefile target in it.
# Run: bash scripts/tests/verify-release-ready-test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAKEFILE="$SCRIPT_DIR/../../Makefile"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/verify-release-ready-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0

# repo <name> <AppVersion> <tag@YYYY-MM-DD>...  → a git repo whose tag creation dates are
# exactly the ones given, so "newest by date" and "newest by version" can disagree.
repo() {
    local name="$1" version="$2"; shift 2
    local dir="$TMP/$name"
    mkdir -p "$dir/Sources/CheICalMCP"
    printf 'enum AppVersion {\n    static let current = "%s"\n}\n' "$version" > "$dir/Sources/CheICalMCP/Version.swift"
    cp "$MAKEFILE" "$dir/Makefile"
    git -C "$dir" init -q
    git -C "$dir" config user.email t@example.invalid
    git -C "$dir" config user.name t
    git -C "$dir" add -A
    GIT_COMMITTER_DATE="2026-01-01T00:00:00+0000" git -C "$dir" commit -q -m init
    local spec tag day
    for spec in "$@"; do
        tag="${spec%@*}"; day="${spec#*@}"
        GIT_COMMITTER_DATE="${day}T12:00:00+0000" git -C "$dir" tag -a -m "$tag" "$tag"
    done
    echo "$dir"
}

# expect <description> <needle in the target's output> <repo dir>
# FALLBACK_FLAGS= on the command line replaces the Makefile's `swift build` probe.
expect() {
    local desc="$1" needle="$2" dir="$3" out rc
    out=$(make -C "$dir" -s verify-release-ready FALLBACK_FLAGS= 2>&1) && rc=0 || rc=$?
    if [ $rc -eq 0 ] && [[ "$out" == *"$needle"* ]]; then
        echo "✓ $desc"; PASS=$((PASS+1))
    else
        echo "✗ $desc — rc=$rc, wanted '$needle', got: $out"; FAIL=$((FAIL+1))
    fi
}

TAGS=(v1.18.0@2026-09-08 v1.19.0@2026-10-04 idd-301-verified@2026-10-09)

expect "an idd-* tag newer than the release is not the latest tag (matches)" \
    "matches latest tag (v1.19.0)" "$(repo same 1.19.0 "${TAGS[@]}")"
expect "an older AppVersion than the latest release tag is a downgrade" \
    "DOWNGRADE drift" "$(repo behind 1.18.5 "${TAGS[@]}")"
expect "a newer AppVersion than the latest release tag is ahead" \
    "AHEAD of latest tag=v1.19.0" "$(repo ahead 1.20.0 "${TAGS[@]}")"
expect "the latest release is chosen by version, not by creation date (v1.10.0 vs v1.9.0)" \
    "matches latest tag (v1.10.0)" "$(repo versions 1.10.0 v1.10.0@2026-01-10 v1.9.0@2026-02-01)"
expect "a repository with only idd-* tags has no release tag yet" \
    "No release tags" "$(repo onlyidd 1.0.0 idd-1-baseline@2026-10-01)"
expect "a repository with no tags at all has no release tag yet" \
    "No release tags" "$(repo none 1.0.0)"

echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
