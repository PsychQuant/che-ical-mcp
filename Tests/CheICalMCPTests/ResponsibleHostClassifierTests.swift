import XCTest
@testable import CheICalMCP

/// Coverage for `ResponsibleHostClassifier.classify` (#343) — the pure mapping from the
/// kernel's responsible-process path to the kind of client macOS charges Calendar and
/// Reminders access to. The diagnostics (`--print-tcc-path`, banner, access-denied
/// message) all phrase their advice from this kind, so each branch is pinned here.
final class ResponsibleHostClassifierTests: XCTestCase {

    func testSelf_winsOverAnyPath() {
        XCTAssertEqual(
            ResponsibleHostClassifier.classify(path: "/Users/u/bin/CheICalMCP", isSelf: true),
            .selfBinary)
        XCTAssertEqual(ResponsibleHostClassifier.classify(path: nil, isSelf: true), .selfBinary)
    }

    func testClaudeCodeVersionedPath_extractsVersion() {
        XCTAssertEqual(
            ResponsibleHostClassifier.classify(
                path: "/Users/u/.local/share/claude/versions/2.1.309", isSelf: false),
            .claudeCode(version: "2.1.309"))
    }

    func testClaudeCodeAppBundlePath_isClaudeCodeWithoutVersion() {
        // The daemon launches resumed workers through this bundle (#343); it carries no
        // Calendar purpose string either, so it must not read as an ordinary app.
        XCTAssertEqual(
            ResponsibleHostClassifier.classify(
                path: "/Users/u/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude", isSelf: false),
            .claudeCode(version: nil))
    }

    func testAppBundlePath_extractsAppName() {
        XCTAssertEqual(
            ResponsibleHostClassifier.classify(
                path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", isSelf: false),
            .appBundle(name: "Visual Studio Code"))
        XCTAssertEqual(
            ResponsibleHostClassifier.classify(
                path: "/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", isSelf: false),
            .appBundle(name: "Terminal"))
    }

    func testNestedAppBundle_namesTheInnermostApp() {
        XCTAssertEqual(
            ResponsibleHostClassifier.classify(
                path: "/Applications/Outer.app/Contents/Frameworks/Inner Helper.app/Contents/MacOS/helper",
                isSelf: false),
            .appBundle(name: "Inner Helper"))
    }

    func testBareExecutable_isOtherExecutable() {
        XCTAssertEqual(
            ResponsibleHostClassifier.classify(path: "/opt/homebrew/bin/tmux", isSelf: false),
            .otherExecutable(path: "/opt/homebrew/bin/tmux"))
    }

    func testMissingPath_isUnknown() {
        XCTAssertEqual(ResponsibleHostClassifier.classify(path: nil, isSelf: false), .unknown)
        XCTAssertEqual(ResponsibleHostClassifier.classify(path: "", isSelf: false), .unknown)
    }

    func testClaudeCodeVersion_acceptsOnlyAVersionToken() {
        // The version is a path component anyone can name, and it is printed into messages an
        // MCP client reads (verify of PR #347) — a hostile or malformed component is dropped.
        XCTAssertEqual(
            ResponsibleHostClassifier.classify(
                path: "/Users/u/.local/share/claude/versions/2.1.309-rc.1+build5", isSelf: false),
            .claudeCode(version: "2.1.309-rc.1+build5"))
        for hostile in ["$(whoami)", "2.1\u{1B}[31m", "a b", "", String(repeating: "9", count: 80)] {
            XCTAssertEqual(
                ResponsibleHostClassifier.classify(
                    path: "/Users/u/.local/share/claude/versions/\(hostile)", isSelf: false),
                .claudeCode(version: nil),
                "hostile version component \(hostile.debugDescription)")
        }
    }
}
