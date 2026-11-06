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
                path: "/Users/u/.local/share/claude/versions/2.1.309", isSelf: false, home: "/Users/u"),
            .claudeCode(version: "2.1.309"))
    }

    func testClaudeCodeAppBundlePath_isClaudeCodeWithoutVersion() {
        // The daemon launches resumed workers through this bundle (#343); it carries no
        // Calendar purpose string either, so it must not read as an ordinary app.
        XCTAssertEqual(
            ResponsibleHostClassifier.classify(
                path: "/Users/u/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude", isSelf: false, home: "/Users/u"),
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

    // MARK: - #356: anchored on the home directory, and the build inside Claude Desktop

    private func kind(_ path: String, home: String = "/Users/u") -> ResponsibleHostKind {
        ResponsibleHostClassifier.classify(path: path, isSelf: false, home: home)
    }

    func testTheNativeFragmentsCountOnlyUnderTheHomeDirectory() {
        XCTAssertEqual(kind("/Users/u/.local/share/claude/versions/2.1.1"), .claudeCode(version: "2.1.1"))
        XCTAssertEqual(kind("/Users/u/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude"), .claudeCode(version: nil))
        XCTAssertEqual(kind("/tmp/x/.local/share/claude/versions/1"), .otherExecutable(path: "/tmp/x/.local/share/claude/versions/1"))
        // Not an app to enable: System Settings has no entry for it (PR #453 verify).
        XCTAssertEqual(kind("/tmp/x/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude"),
                       .otherExecutable(path: "/tmp/x/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude"))
        XCTAssertEqual(kind("/Users/other/.local/share/claude/versions/1"), .otherExecutable(path: "/Users/other/.local/share/claude/versions/1"))
    }

    /// The layout and bundle id were read from an installed Claude Desktop (2026-11-06).
    func testClaudeDesktopsBundledBuildIsClaudeCode() {
        let bundled = "/Users/u/Library/Application Support/Claude/claude-code/2.1.317/91184d3d9ba3/claude.app/Contents/MacOS/claude"
        XCTAssertEqual(kind(bundled), .claudeCode(version: "2.1.317"))
        XCTAssertEqual(kind("/Users/u/Library/Application Support/Claude/claude-code/$(id)/h/claude.app/Contents/MacOS/claude"),
                       .claudeCode(version: nil), "the version is printed into messages, so only a version token is kept")
        XCTAssertEqual(kind("/Users/other/Library/Application Support/Claude/claude-code/2.1.317/h/claude.app/Contents/MacOS/claude"),
                       .appBundle(name: "claude"))
    }

    /// PR #453 verify: the kernel reports the resolved path, and `NSHomeDirectory()` the path as
    /// the directory service gives it, so a home that is a symlink, or root's `/var/root`, would
    /// miss every prefix.
    func testAHomeThatIsASymlinkMatchesThroughItsResolvedPath() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("HostHome-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real"), link = base.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let resolved = try XCTUnwrap(realpath(real.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        for home in [link.path, link.path + "/"] {
            XCTAssertEqual(kind(resolved + "/.local/share/claude/versions/2.1.1", home: home), .claudeCode(version: "2.1.1"))
            XCTAssertEqual(kind(resolved + "/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude", home: home), .claudeCode(version: nil))
            XCTAssertEqual(kind(resolved + "/Library/Application Support/Claude/claude-code/2.1.317/h/claude.app/Contents/MacOS/claude", home: home),
                           .claudeCode(version: "2.1.317"))
            XCTAssertEqual(kind(link.path + "/.local/share/claude/versions/2.1.1", home: home), .claudeCode(version: "2.1.1"),
                           "the home as given still counts")
        }
    }

    /// `ClaudeCode.app` where `~/.local` is a symlink, or under another root, misses the prefixes,
    /// and no wording may name it as an app to enable. Another app of that name would too.
    func testAClaudeCodeBundleOutsideTheRootsIsNotAnAppToEnable() {
        let path = "/Users/u/dotfiles/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude"
        XCTAssertEqual(kind(path), .otherExecutable(path: path))
        XCTAssertEqual(kind("/Applications/Claude.app/Contents/MacOS/Claude"), .appBundle(name: "Claude"), "only this bundle name")
    }

    func testAPrefixHasToEndAtADirectory() {
        XCTAssertEqual(kind("/Users/u2/.local/share/claude/versions/1"), .otherExecutable(path: "/Users/u2/.local/share/claude/versions/1"))
        XCTAssertEqual(kind("/Users/u/Library/Application Support/Claude/claude-code-other/1/x"),
                       .otherExecutable(path: "/Users/u/Library/Application Support/Claude/claude-code-other/1/x"))
    }

    func testATrailingSlashOnTheHomeDirectoryChangesNothing() {
        XCTAssertEqual(kind("/Users/u/.local/share/claude/versions/2.1.1", home: "/Users/u/"), .claudeCode(version: "2.1.1"))
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
                path: "/Users/u/.local/share/claude/versions/2.1.309-rc.1+build5", isSelf: false, home: "/Users/u"),
            .claudeCode(version: "2.1.309-rc.1+build5"))
        for hostile in ["$(whoami)", "2.1\u{1B}[31m", "a b", "", String(repeating: "9", count: 80)] {
            XCTAssertEqual(
                ResponsibleHostClassifier.classify(
                    path: "/Users/u/.local/share/claude/versions/\(hostile)", isSelf: false, home: "/Users/u"),
                .claudeCode(version: nil),
                "hostile version component \(hostile.debugDescription)")
        }
    }
}
