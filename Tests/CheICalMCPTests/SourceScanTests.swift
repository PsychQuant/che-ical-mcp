import Foundation
import XCTest

/// The helper behind the source-text guards of #260 and #246 (`Helpers/SourceScan.swift`). A
/// guard that loses track of comments, or that skips when the source tree moved, passes while the
/// code it guards regresses.
final class SourceScanTests: XCTestCase {
    // MARK: - Comments, line endings and literals

    /// Swift treats "\r\n" as one `Character`; a line comment must still end at it.
    func testALineCommentEndsAtACRLFLineEnding() {
        XCTAssertEqual(SourceScan.strippingComments("a // c\r\nb"), "a     \r\nb")
        let text = "// c\r\nlet a = 1\r\n/* d\r\n */ let b = 2\r\n"
        let stripped = SourceScan.strippingComments(text)
        XCTAssertEqual(stripped.unicodeScalars.filter { $0 == "\n" }.count, 4)
        XCTAssertTrue(stripped.contains("let a = 1"), stripped)
        XCTAssertTrue(stripped.contains("let b = 2"), stripped)
    }

    /// A quote followed by a combining mark is one `Character` but still opens the literal.
    func testAQuoteFollowedByACombiningMarkStillOpensAString() {
        let text = "let s = \"\u{301}//\"; let b = 2"
        XCTAssertEqual(SourceScan.strippingComments(text), text)
    }

    func testAnExtendedRegexLiteralIsNotAComment() {
        let one = "let r = #/https?://\\S+/#; let b = 2"
        XCTAssertEqual(SourceScan.strippingComments(one), one)
        let multi = "let r = #/\n  a // b\n/#\nlet b = 2"
        XCTAssertEqual(SourceScan.strippingComments(multi), multi)
        let hashes = "let r = ##/a/#b//##; let b = 2"
        XCTAssertEqual(SourceScan.strippingComments(hashes), hashes)
    }

    /// In a bare regex literal a `/` is escaped, so an escaped slash next to the closing one is
    /// not a `//`.
    func testEscapedSlashesInABareRegexLiteralAreNotAComment() {
        let text = "let r = /https?:\\/\\//; let b = 2"
        XCTAssertEqual(SourceScan.strippingComments(text), text)
    }

    func testKeyPathsAndStringsAreKept() {
        let text = #"let t = items.map(\.title); let u = "a//b" // gone"#
        XCTAssertEqual(SourceScan.strippingComments(text), #"let t = items.map(\.title); let u = "a//b"        "#)
    }

    // MARK: - Locating the source tree

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceScanTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func make(_ path: String, file: Bool) throws -> URL {
        let url = scratch.appendingPathComponent(path)
        if file {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    func testWithoutPackageSwiftTheScanIsSkipped() throws {
        let start = try make("Tests/T", file: false)
        XCTAssertThrowsError(try SourceScan.sourcesDirectory(from: start)) { error in
            XCTAssertTrue(error is XCTSkip, "\(error)")
        }
    }

    func testAPackageWithoutTheSourcesDirectoryFails() throws {
        _ = try make("Package.swift", file: true)
        let start = try make("Tests/T", file: false)
        XCTAssertThrowsError(try SourceScan.sourcesDirectory(from: start)) { error in
            XCTAssertFalse(error is XCTSkip, "a moved source tree must fail the guard, not skip it")
        }
    }

    func testASourcesDirectoryWithoutSwiftFilesFails() throws {
        _ = try make("Package.swift", file: true)
        _ = try make("Sources/CheICalMCP/README.md", file: true)
        let start = try make("Tests/T", file: false)
        let root = try SourceScan.sourcesDirectory(from: start)
        XCTAssertEqual(root.standardizedFileURL.path,
                       scratch.appendingPathComponent("Sources/CheICalMCP").standardizedFileURL.path)
        XCTAssertThrowsError(try SourceScan.swiftFiles(under: root)) { error in
            XCTAssertFalse(error is XCTSkip, "an empty source tree must fail the guard, not skip it")
        }
    }

    func testTheSwiftFilesUnderTheSourcesDirectoryAreListed() throws {
        _ = try make("Package.swift", file: true)
        _ = try make("Sources/CheICalMCP/A.swift", file: true)
        _ = try make("Sources/CheICalMCP/Sub/B.swift", file: true)
        _ = try make("Sources/CheICalMCP/C.md", file: true)
        let root = try SourceScan.sourcesDirectory(from: try make("Tests/T", file: false))
        XCTAssertEqual(try SourceScan.swiftFiles(under: root).map(\.lastPathComponent).sorted(), ["A.swift", "B.swift"])
    }
}
