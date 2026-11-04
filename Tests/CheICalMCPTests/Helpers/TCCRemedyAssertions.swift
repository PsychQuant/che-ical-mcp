import XCTest

/// Shared checks for the TCC remedy text (#357, minimal scope after verify round 3).
///
/// - `tccutil reset <service> com.checheng.CheICalMCP` fails with -10814 for a bare binary, so
///   no code surface prints it.
/// - No code surface prints a machine-wide `tccutil reset` either (text returned to the model,
///   the banner and `--print-tcc-path`, which agents read).
/// - Where the bundle-id reset stood: main's existing switch sentence (round 4, R1).
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

    /// Round 4 (R1): where the bundle-id reset stood, the System Settings switch sentence that
    /// main already uses in the self-attributed, already-denied branch, adapted only for the pane
    /// name, with "#382" as the pointer to the open device question. No claim about what
    /// `--print-tcc-path` shows (run from Terminal it reports Terminal's context).
    static func assertSwitchRemedy(
        _ text: String, pane: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        assertNoReset(text, file: file, line: line)
        XCTAssertTrue(text.contains("witch CheICalMCP on in System Settings → Privacy & Security → \(pane) (#382)"),
                      text, file: file, line: line)
        XCTAssertFalse(text.contains("to see which process macOS checks"), text, file: file, line: line)
        XCTAssertFalse(text.contains("re-checking"), text, file: file, line: line)
        XCTAssertFalse(text.contains("off and on"), text, file: file, line: line)
    }
}
