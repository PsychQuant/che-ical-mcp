import XCTest

/// Shared checks for the TCC remedy text (#357, verify rounds 1–2).
///
/// - `tccutil reset <service> com.checheng.CheICalMCP` fails with -10814 for a bare binary,
///   so no surface may print `tccutil reset` with a bundle id.
/// - The Calendar / Reminders panes have no remove or add button (observed on one Mac,
///   macOS 27), so no surface may tell the user to press one or to remove CheICalMCP.
/// - Round-2 policy P1: text returned to the model never carries a bare reset either; for a
///   stale grant it sends a person at the Mac to `--print-tcc-path`.
/// - Round-2 policy P2: a human-run surface may give the bare reset as the last resort, with
///   the every-app consequence, the v1.11.0+ precondition and "run it yourself".
enum TCCRemedyAssertions {
    static func assertNoBundleIDResetAndNoButton(
        _ text: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(text.contains("−"), "no remove button exists in the pane: \(text)", file: file, line: line)
        XCTAssertFalse(text.lowercased().contains("button"), "the pane has only switches and Options…: \(text)", file: file, line: line)
        XCTAssertFalse(text.contains("remove CheICalMCP"), text, file: file, line: line)
        XCTAssertFalse(text.contains("manually add"), "the pane has no add button: \(text)", file: file, line: line)
        XCTAssertFalse(text.contains("click +"), "the pane has no add button: \(text)", file: file, line: line)
        for row in text.components(separatedBy: "\n") where row.contains("tccutil reset") {
            XCTAssertFalse(row.contains("com.checheng"), "tccutil reset with the bundle id: \(row)", file: file, line: line)
            XCTAssertTrue(row.contains("every app"),
                          "a bare reset must say it clears the permission for every app: \(row)", file: file, line: line)
        }
    }

    /// P1: MCP-facing text has no reset of any kind, and a stale grant goes to a person at the
    /// Mac running `--print-tcc-path`.
    static func assertMCPFacingStaleGrant(
        _ text: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        assertNoBundleIDResetAndNoButton(text, file: file, line: line)
        XCTAssertFalse(text.contains("tccutil"), "no reset in MCP-facing text: \(text)", file: file, line: line)
        XCTAssertTrue(text.contains("person at the Mac"), text, file: file, line: line)
        XCTAssertTrue(text.contains("--print-tcc-path"), text, file: file, line: line)
    }

    /// P3: the switch step.
    static func assertSwitchStep(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(text.contains("switch CheICalMCP off and on in System Settings → Privacy & Security →"), text, file: file, line: line)
        XCTAssertTrue(text.contains("or set it with its Options… menu"), text, file: file, line: line)
        XCTAssertTrue(text.contains("if two CheICalMCP rows are listed"), text, file: file, line: line)
        XCTAssertTrue(text.contains("one at a time"), text, file: file, line: line)
        XCTAssertTrue(text.contains("--print-tcc-path after each"), text, file: file, line: line)
    }

    /// P2: the human-run last resort, with all three of consequence, precondition, run-yourself.
    static func assertHumanLastResort(
        _ text: String, service: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        assertNoBundleIDResetAndNoButton(text, file: file, line: line)
        guard let row = text.components(separatedBy: "\n").first(where: { $0.contains("tccutil reset \(service)`") }) else {
            return XCTFail("no bare reset line for \(service): \(text)", file: file, line: line)
        }
        XCTAssertTrue(row.contains("last resort"), row, file: file, line: line)
        XCTAssertTrue(row.contains("every app"), row, file: file, line: line)
        XCTAssertTrue(row.contains("version number may not ask again"), row, file: file, line: line)
        XCTAssertTrue(row.contains("v1.11.0"), row, file: file, line: line)
        XCTAssertTrue(row.contains("yourself"), row, file: file, line: line)
    }
}
