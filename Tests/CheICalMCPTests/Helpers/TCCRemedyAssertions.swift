import XCTest

/// Shared checks for the TCC remedy text (#357, minimal scope after verify round 3).
///
/// - `tccutil reset <service> com.checheng.CheICalMCP` fails with -10814 for a bare binary, so
///   no code surface prints it.
/// - No code surface prints a machine-wide `tccutil reset` either (text returned to the model,
///   the banner and `--print-tcc-path`, which agents read).
/// - Where the bundle-id reset stood, the text is status- and attribution-agnostic: see which
///   process macOS checks with `--print-tcc-path`, switch that entry on or off and on, one
///   CheICalMCP row at a time, and the switch is not confirmed to clear a mismatch (#382).
/// - The Calendar / Reminders panes have no remove or add button (observed on one Mac,
///   macOS 27).
enum TCCRemedyAssertions {
    static func assertNoReset(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.contains("tccutil"), "no reset of any kind: \(text)", file: file, line: line)
        XCTAssertFalse(text.contains("−"), "no remove button: \(text)", file: file, line: line)
        XCTAssertFalse(text.lowercased().contains("button"), "only switches and Options…: \(text)", file: file, line: line)
        XCTAssertFalse(text.contains("remove CheICalMCP"), text, file: file, line: line)
        XCTAssertFalse(text.contains("manually add"), "no add button: \(text)", file: file, line: line)
    }

    static func assertAgnosticRemedy(
        _ text: String, pane: String, printTCCPathHint: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        assertNoReset(text, file: file, line: line)
        XCTAssertTrue(text.contains("--print-tcc-path on the Mac to see which process macOS checks"), text, file: file, line: line)
        if let printTCCPathHint {
            XCTAssertTrue(text.contains("run \(printTCCPathHint) on the Mac"), text, file: file, line: line)
        }
        XCTAssertTrue(text.contains("in System Settings → Privacy & Security → \(pane) switch that entry on, or off and on"),
                      text, file: file, line: line)
        XCTAssertTrue(text.contains("if two CheICalMCP rows are listed, one at a time, re-checking --print-tcc-path"),
                      text, file: file, line: line)
        XCTAssertTrue(text.contains("whether the switch clears a code-requirement mismatch is not yet confirmed (#382)"),
                      text, file: file, line: line)
    }
}
