import XCTest
@testable import CheICalMCP

/// Coverage for `ResponsibleProcessFormatter` (#343) — the `--print-tcc-path` attribution
/// block and the per-kind advice the banner and access-denied message reuse. The advice
/// must name the client macOS actually checks; naming the parent chain's host instead is
/// the misdirection #343 was filed for.
final class ResponsibleProcessFormatterTests: XCTestCase {

    func testSelfBinary_marksThisBinaryAndNamesItsOwnGrant() {
        let s = ResponsibleProcessFormatter.attributionSection(
            selfPid: 500,
            result: .resolved(ResponsibleProcess(pid: 500, path: "/Users/u/bin/CheICalMCP", isSelf: true)))
        XCTAssertTrue(s.contains("TCC attribution"))
        XCTAssertTrue(s.contains("500  /Users/u/bin/CheICalMCP  (this binary)"))
        XCTAssertTrue(s.contains("CheICalMCP's own grant"))
    }

    func testAppBundleHost_namesTheApp() {
        let s = ResponsibleProcessFormatter.attributionSection(
            selfPid: 500,
            result: .resolved(ResponsibleProcess(
                pid: 3599, path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", isSelf: false)))
        XCTAssertTrue(s.contains("3599  /Applications/Visual Studio Code.app/Contents/MacOS/Electron"))
        XCTAssertFalse(s.contains("(this binary)"))
        XCTAssertTrue(s.contains("Visual Studio Code's grant"))
    }

    func testClaudeCodeHost_explainsItCannotBePromptedAndHowToFix() {
        let advice = ResponsibleProcessFormatter.advice(for: .claudeCode(version: "2.1.309"))
        XCTAssertTrue(advice.contains("Claude Code 2.1.309"))
        XCTAssertTrue(advice.contains("no Calendar or Reminders purpose string"))
        XCTAssertTrue(advice.contains("CHE_ICAL_MCP_NO_DISCLAIM"))
    }

    func testUnavailable_rendersTheReason() {
        let s = ResponsibleProcessFormatter.attributionSection(
            selfPid: 500, result: .unavailable(reason: "responsibility SPI not found in this macOS"))
        XCTAssertTrue(s.contains("(responsible process unavailable: responsibility SPI not found in this macOS)"))
    }

    func testMissingPath_isVisible() {
        let s = ResponsibleProcessFormatter.attributionSection(
            selfPid: 500, result: .resolved(ResponsibleProcess(pid: 77, path: nil, isSelf: false)))
        XCTAssertTrue(s.contains("77  (no path reported)"))
    }

    func testControlCharactersInThePath_areEscaped() {
        let s = ResponsibleProcessFormatter.attributionSection(
            selfPid: 500,
            result: .resolved(ResponsibleProcess(pid: 9, path: "/tmp/\u{1B}[2J.app/Contents/MacOS/x", isSelf: false)))
        XCTAssertFalse(s.unicodeScalars.contains { $0.value == 0x1B }, "raw ESC must never reach stdout")
    }
}
