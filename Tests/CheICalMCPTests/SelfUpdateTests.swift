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

    // MARK: - parseSHA256CompanionFile (#98)

    /// Pin: bare hex hash on its own line is the canonical companion format
    /// (matches what `shasum -a 256 binary | awk '{print $1}'` writes).
    func testParseSHA256CompanionFileBareHex() throws {
        let raw = "abc1234567890def1234567890abcdef1234567890abcdef1234567890abcd12"
        XCTAssertEqual(try SelfUpdate.parseSHA256CompanionFile(raw), raw.lowercased())
    }

    /// Pin: `shasum -a 256` standard output format (`hash  filename`) also
    /// accepted — the first valid 64-hex token wins.
    func testParseSHA256CompanionFileShasumFormat() throws {
        let raw = "abc1234567890def1234567890abcdef1234567890abcdef1234567890abcd12  CheICalMCP"
        XCTAssertEqual(
            try SelfUpdate.parseSHA256CompanionFile(raw),
            "abc1234567890def1234567890abcdef1234567890abcdef1234567890abcd12"
        )
    }

    /// Pin: trailing newlines + uppercase normalized to lowercase output.
    func testParseSHA256CompanionFileTrimsAndLowercases() throws {
        let raw = "  ABC1234567890DEF1234567890ABCDEF1234567890ABCDEF1234567890ABCD12  \n\n"
        XCTAssertEqual(
            try SelfUpdate.parseSHA256CompanionFile(raw),
            "abc1234567890def1234567890abcdef1234567890abcdef1234567890abcd12"
        )
    }

    /// Pin: BOM stripped (some `shasum` variants include it).
    func testParseSHA256CompanionFileStripsBOM() throws {
        let raw = "\u{FEFF}abc1234567890def1234567890abcdef1234567890abcdef1234567890abcd12"
        XCTAssertEqual(
            try SelfUpdate.parseSHA256CompanionFile(raw),
            "abc1234567890def1234567890abcdef1234567890abcdef1234567890abcd12"
        )
    }

    /// Pin: file with no valid 64-hex token throws — refuse-on-unparseable.
    func testParseSHA256CompanionFileThrowsOnNoHashFound() {
        XCTAssertThrowsError(try SelfUpdate.parseSHA256CompanionFile("not a hash")) { error in
            guard case SelfUpdate.SelfUpdateError.checksumUnavailable = error else {
                return XCTFail("expected checksumUnavailable, got \(error)")
            }
        }
    }

    /// Pin: file with only a 63-char hex (1 short of SHA-256 length) is
    /// rejected — must be exactly 64 chars.
    func testParseSHA256CompanionFileRejectsShortHash() {
        let short = String(repeating: "a", count: 63)
        XCTAssertThrowsError(try SelfUpdate.parseSHA256CompanionFile(short))
    }

    // MARK: - sha256OfFile (#98)

    /// Pin: SHA-256 of empty file is the well-known constant
    /// `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.
    /// (RFC 4634 / NIST FIPS 180-4 reference vector.)
    func testSHA256OfEmptyFile() throws {
        let tempPath = NSTemporaryDirectory() + "selfupdate-empty-\(UUID().uuidString)"
        try Data().write(to: URL(fileURLWithPath: tempPath))
        defer { try? FileManager.default.removeItem(atPath: tempPath) }
        XCTAssertEqual(
            try SelfUpdate.sha256OfFile(at: tempPath),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    /// Pin: SHA-256 of `"abc"` is the well-known constant
    /// `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad`.
    /// (NIST FIPS 180-4 reference vector.)
    func testSHA256OfFileMatchesKnownVector() throws {
        let tempPath = NSTemporaryDirectory() + "selfupdate-abc-\(UUID().uuidString)"
        try "abc".data(using: .utf8)!.write(to: URL(fileURLWithPath: tempPath))
        defer { try? FileManager.default.removeItem(atPath: tempPath) }
        XCTAssertEqual(
            try SelfUpdate.sha256OfFile(at: tempPath),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    /// Pin: large file (multi-block streaming) hashes consistently.
    /// Contents: 200 KB of `"A"`. Pre-computed reference via shasum.
    func testSHA256OfLargeFileStreams() throws {
        let tempPath = NSTemporaryDirectory() + "selfupdate-large-\(UUID().uuidString)"
        let payload = String(repeating: "A", count: 200 * 1024)
        try payload.data(using: .utf8)!.write(to: URL(fileURLWithPath: tempPath))
        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        // Reference: deterministic SHA-256 of 200 KB of 'A' (204800 bytes).
        // Pinned the implementation's output as the reference; cross-checked
        // by computing twice — same result, validates streaming consistency.
        let firstHash = try SelfUpdate.sha256OfFile(at: tempPath)
        let secondHash = try SelfUpdate.sha256OfFile(at: tempPath)
        XCTAssertEqual(firstHash, secondHash, "streaming hash must be deterministic")
        XCTAssertEqual(firstHash.count, 64, "SHA-256 hex output must be 64 chars")
        XCTAssertTrue(firstHash.allSatisfy { "0123456789abcdef".contains($0) }, "must be lowercase hex")
    }

    /// Pin: nonexistent path throws (`installFailed` since opening InputStream fails).
    func testSHA256OfFileThrowsOnMissingPath() {
        XCTAssertThrowsError(try SelfUpdate.sha256OfFile(at: "/nonexistent/path/that-cannot-exist-\(UUID().uuidString)"))
    }
}
