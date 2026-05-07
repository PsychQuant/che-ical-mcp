import XCTest

@testable import CheICalMCP

/// Pure-function tests for `SelfUpdate` (#49).
///
/// Network-dependent paths (`fetchLatestTag`, `downloadBinary`) are NOT
/// tested here — they need GitHub Releases API access. Pinning those
/// would require a fake URLSession or VCR-style cassettes, both more
/// infrastructure than the value justifies for this single command.
///
/// What IS pinned: the version-comparison + URL-shape pure helpers
/// that are easy to get subtly wrong (off-by-one on prerelease, wrong
/// asset URL pattern, etc.).
final class SelfUpdateTests: XCTestCase {

    // MARK: - stripTagPrefix

    func testStripTagPrefixRemovesLeadingV() {
        XCTAssertEqual(SelfUpdate.stripTagPrefix("v1.7.1"), "1.7.1")
        XCTAssertEqual(SelfUpdate.stripTagPrefix("v0.0.1"), "0.0.1")
        XCTAssertEqual(SelfUpdate.stripTagPrefix("v1.0.0-rc.1"), "1.0.0-rc.1")
    }

    func testStripTagPrefixHandlesNoPrefix() {
        // Some release workflows don't prepend `v`. Helper should be tolerant.
        XCTAssertEqual(SelfUpdate.stripTagPrefix("1.7.1"), "1.7.1")
        XCTAssertEqual(SelfUpdate.stripTagPrefix(""), "")
    }

    func testStripTagPrefixDoesNotTouchInternalV() {
        // `vNext` is plausible (sentinel branch); only LEADING v gets stripped.
        XCTAssertEqual(SelfUpdate.stripTagPrefix("v1.7.1-vNext"), "1.7.1-vNext")
    }

    // MARK: - isNewer (semver-ish comparison)

    func testIsNewerStandardVersionBumps() {
        XCTAssertTrue(SelfUpdate.isNewer(candidate: "1.7.2", than: "1.7.1"))
        XCTAssertTrue(SelfUpdate.isNewer(candidate: "1.8.0", than: "1.7.99"))
        XCTAssertTrue(SelfUpdate.isNewer(candidate: "2.0.0", than: "1.99.99"))
    }

    func testIsNewerHandlesIdenticalVersions() {
        XCTAssertFalse(SelfUpdate.isNewer(candidate: "1.7.1", than: "1.7.1"))
    }

    func testIsNewerHandlesDowngrade() {
        XCTAssertFalse(SelfUpdate.isNewer(candidate: "1.6.0", than: "1.7.1"))
        XCTAssertFalse(SelfUpdate.isNewer(candidate: "1.7.0", than: "1.7.1"))
    }

    func testIsNewerHandlesDifferentComponentCounts() {
        // "1.7.1.0" vs "1.7.1" — extra .0 means same; missing components
        // are compared as 0.
        XCTAssertFalse(SelfUpdate.isNewer(candidate: "1.7.1", than: "1.7.1.0"))
        XCTAssertFalse(SelfUpdate.isNewer(candidate: "1.7.1.0", than: "1.7.1"))
        XCTAssertTrue(SelfUpdate.isNewer(candidate: "1.7.1.1", than: "1.7.1"))
    }

    func testIsNewerHandlesNumericGreaterTen() {
        // Lexicographic would say "1.7.10" < "1.7.9". Numeric should say >.
        XCTAssertTrue(SelfUpdate.isNewer(candidate: "1.7.10", than: "1.7.9"))
        XCTAssertTrue(SelfUpdate.isNewer(candidate: "1.10.0", than: "1.9.99"))
    }

    func testIsNewerFallsBackToLexicographicForNonNumeric() {
        // Prerelease components like "rc.1" vs "rc.2" — neither is Int,
        // lexicographic comparison kicks in.
        XCTAssertTrue(SelfUpdate.isNewer(candidate: "1.0.0-rc.2", than: "1.0.0-rc.1"))
    }

    // MARK: - makeAssetDownloadURL

    func testMakeAssetDownloadURLProducesExpectedShape() {
        let url = SelfUpdate.makeAssetDownloadURL(tag: "v1.7.1", assetName: "CheICalMCP")
        XCTAssertEqual(
            url.absoluteString,
            "https://github.com/PsychQuant/che-ical-mcp/releases/download/v1.7.1/CheICalMCP"
        )
    }

    func testMakeAssetDownloadURLPreservesTagPrefix() {
        // `v` is part of the tag in the URL path — stripTagPrefix is for
        // display + comparison, NOT for URL construction.
        let url = SelfUpdate.makeAssetDownloadURL(tag: "v1.7.1", assetName: "CheICalMCP")
        XCTAssertTrue(url.absoluteString.contains("/v1.7.1/"))
    }
}
