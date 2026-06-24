import XCTest

@testable import CheICalMCP

/// Pure-unit matrix tests for `NonInteractiveDetection.isNonInteractive` (#149, #165).
///
/// This is an **independent oracle**: each row's `expected` is hand-derived from
/// the spec ("non-interactive when launchd child OR no GUI session OR (includeCI && CI)"),
/// NOT recomputed from the production formula.
///
/// The load-bearing rows:
/// - **#165 fix**: GUI session present but no TTY (a GUI-app-spawned MCP server, e.g.
///   Claude Desktop) is **interactive** — a dialog can appear in the Aqua session. The old
///   `TERM == nil` form wrongly flagged this non-interactive, so `requestFullAccess` was
///   never called and the Calendar dialog never appeared through Claude Desktop.
/// - **#143 carve-out**: `CI` set with `includeCI: true` (gate) is non-interactive; with
///   `includeCI: false` (`--setup`) it is NOT — a human in Terminal.app with `CI=1` still
///   gets the dialog.
final class NonInteractiveDetectionTests: XCTestCase {

    private let LAUNCHD: pid_t = 1
    private let NORMAL: pid_t = 42  // any non-1 parent

    private func env(ci: Bool) -> [String: String] {
        ci ? ["CI": "1"] : [:]
    }

    private func assertCase(
        guiSession: Bool, ci: Bool, ppid: pid_t, includeCI: Bool,
        expected: Bool, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            NonInteractiveDetection.isNonInteractive(
                env: env(ci: ci), ppid: ppid, hasGUISession: guiSession, includeCI: includeCI),
            expected, label, file: file, line: line)
    }

    /// Fully interactive (GUI session, not launchd, no CI) → interactive under both modes.
    func testInteractiveBaseline_falseBothModes() {
        assertCase(guiSession: true, ci: false, ppid: NORMAL, includeCI: true,  expected: false, "interactive, gate mode")
        assertCase(guiSession: true, ci: false, ppid: NORMAL, includeCI: false, expected: false, "interactive, --setup mode")
    }

    /// #165 fix: a GUI-app-spawned process (Claude Desktop → MCP server) has a GUI session
    /// but no controlling TTY. It MUST be interactive — a TCC dialog can present in the Aqua
    /// session. (The old `TERM == nil` form returned true here, the root-cause bug.)
    func testGUIAppSpawnedNoTTY_isInteractive_bothModes() {
        assertCase(guiSession: true, ci: false, ppid: NORMAL, includeCI: true,  expected: false,
            "GUI session + no TTY (Claude Desktop spawn) is interactive — gate mode (#165)")
        assertCase(guiSession: true, ci: false, ppid: NORMAL, includeCI: false, expected: false,
            "GUI session + no TTY is interactive — --setup mode (#165)")
    }

    /// The #143 carve-out: CI set, GUI session present, not launchd.
    /// gate (`includeCI: true`) → non-interactive; `--setup` (`includeCI: false`) → interactive.
    func testCIOnly_distinguishesGateFromSetup() {
        assertCase(guiSession: true, ci: true, ppid: NORMAL, includeCI: true,  expected: true,
            "CI runner is non-interactive for the MCP server gate (#131)")
        assertCase(guiSession: true, ci: true, ppid: NORMAL, includeCI: false, expected: false,
            "CI must NOT force --setup to skip — human in Terminal with CI=1 still gets the dialog (#143)")
    }

    /// No GUI session (truly headless: system launchd daemon / SSH without GUI) → non-interactive.
    func testNoGUISession_trueBothModes() {
        assertCase(guiSession: false, ci: false, ppid: NORMAL, includeCI: true,  expected: true, "no GUI session, gate mode")
        assertCase(guiSession: false, ci: false, ppid: NORMAL, includeCI: false, expected: true, "no GUI session, --setup mode")
    }

    /// Direct launchd child (`ppid == 1`) → non-interactive regardless of everything else.
    func testLaunchdChild_trueBothModes() {
        assertCase(guiSession: true, ci: false, ppid: LAUNCHD, includeCI: true,  expected: true, "launchd, gate mode")
        assertCase(guiSession: true, ci: false, ppid: LAUNCHD, includeCI: false, expected: true, "launchd, --setup mode")
        // ppid==1 dominates even with a GUI session present + CI excluded.
        assertCase(guiSession: true, ci: true, ppid: LAUNCHD, includeCI: false, expected: true, "launchd dominates")
    }

    /// Combined signals still resolve to non-interactive (OR semantics).
    func testCombinedSignals_true() {
        assertCase(guiSession: false, ci: true, ppid: LAUNCHD, includeCI: true,  expected: true, "all signals, gate mode")
        assertCase(guiSession: false, ci: true, ppid: LAUNCHD, includeCI: false, expected: true, "all signals, --setup mode")
    }

    /// `EventKitManager.isNonInteractive` (the wired-up static) delegates to the helper with
    /// the production GUI-session probe — pin that the seam reflects the current process.
    func testEventKitManagerStaticMatchesHelper() {
        let expected = NonInteractiveDetection.isNonInteractive(
            env: ProcessInfo.processInfo.environment, ppid: getppid(),
            hasGUISession: NonInteractiveDetection.hasGUISession, includeCI: true)
        XCTAssertEqual(EventKitManager.isNonInteractive, expected,
            "EventKitManager.isNonInteractive must delegate to NonInteractiveDetection (gate mode)")
    }
}
