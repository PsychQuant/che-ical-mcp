import XCTest

/// Shared checks for the TCC remedy text (#357 and its verify round).
///
/// - `tccutil reset <service> com.checheng.CheICalMCP` fails with -10814 for a bare binary,
///   so no surface may print `tccutil reset` with a bundle id.
/// - The only `tccutil reset` a surface may print is the bare one, as the last resort, and
///   the same line must say it clears the permission for every app.
/// - The Calendar / Reminders panes have no "−" (remove) button (observed on macOS 27), so no
///   surface may tell the user to press one.
enum TCCRemedyAssertions {
    static func assertNoBundleIDResetAndNoMinusButton(
        _ text: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(text.contains("−"), "no − (remove) button exists in the pane: \(text)", file: file, line: line)
        XCTAssertFalse(text.contains("com.checheng.CheICalMCP`"), "no bundle-id reset: \(text)", file: file, line: line)
        for row in text.components(separatedBy: "\n") where row.contains("tccutil reset") {
            XCTAssertFalse(row.contains("com.checheng"), "tccutil reset with the bundle id: \(row)", file: file, line: line)
            XCTAssertTrue(row.contains("every app"),
                          "a bare reset must say it clears the permission for every app: \(row)", file: file, line: line)
        }
    }

    /// The stale-grant remedy: off and on (or Options…) in the pane, `--setup`, and the bare
    /// reset only as the last resort with its consequence.
    static func assertStaleGrantRemedy(
        _ text: String, service: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        assertNoBundleIDResetAndNoMinusButton(text, file: file, line: line)
        XCTAssertTrue(text.contains("off and on"), text, file: file, line: line)
        XCTAssertTrue(text.contains("Options…"), text, file: file, line: line)
        XCTAssertTrue(text.contains("--setup"), text, file: file, line: line)
        XCTAssertTrue(text.contains("tccutil reset \(service)`"), "last resort, bare: \(text)", file: file, line: line)
        XCTAssertTrue(text.contains("last resort"), text, file: file, line: line)
    }
}
