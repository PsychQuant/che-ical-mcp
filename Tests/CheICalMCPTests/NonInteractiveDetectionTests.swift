import XCTest

@testable import CheICalMCP

/// Pure-unit matrix tests for `NonInteractiveDetection.isNonInteractive` (#149).
///
/// This is an **independent oracle**: each row's `expected` is hand-derived from
/// the spec ("non-interactive when launchd child OR no TTY OR (includeCI && CI)"),
/// NOT recomputed from the production formula — so it would catch a formula written
/// wrong in the same direction (the gap the PR #148 mirror-style test could not).
///
/// The load-bearing row is the `CI`-only case: with `includeCI: true` (MCP server
/// gate) it is non-interactive; with `includeCI: false` (`--setup`) it is NOT — that
/// is the #143 carve-out that lets a human in Terminal.app with `CI=1` exported still
/// get the TCC dialog.
final class NonInteractiveDetectionTests: XCTestCase {

    private let LAUNCHD: pid_t = 1
    private let NORMAL: pid_t = 42  // any non-1 parent

    private func env(term: Bool, ci: Bool) -> [String: String] {
        var e: [String: String] = [:]
        if term { e["TERM"] = "xterm-256color" }
        if ci { e["CI"] = "1" }
        return e
    }

    private func assertCase(
        term: Bool, ci: Bool, ppid: pid_t, includeCI: Bool,
        expected: Bool, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            NonInteractiveDetection.isNonInteractive(env: env(term: term, ci: ci), ppid: ppid, includeCI: includeCI),
            expected, label, file: file, line: line)
    }

    /// Fully interactive (TTY present, not launchd, no CI) → interactive under both modes.
    func testInteractiveBaseline_falseBothModes() {
        assertCase(term: true, ci: false, ppid: NORMAL, includeCI: true,  expected: false, "interactive, gate mode")
        assertCase(term: true, ci: false, ppid: NORMAL, includeCI: false, expected: false, "interactive, --setup mode")
    }

    /// The #143 carve-out: CI set, TTY present, not launchd.
    /// gate (`includeCI: true`) → non-interactive; `--setup` (`includeCI: false`) → interactive.
    func testCIOnly_distinguishesGateFromSetup() {
        assertCase(term: true, ci: true, ppid: NORMAL, includeCI: true,  expected: true,
            "CI runner is non-interactive for the MCP server gate (#131)")
        assertCase(term: true, ci: true, ppid: NORMAL, includeCI: false, expected: false,
            "CI must NOT force --setup to skip — human in Terminal with CI=1 still gets the dialog (#143)")
    }

    /// No controlling TTY (`TERM` unset) → non-interactive regardless of includeCI/CI/ppid.
    func testNoTTY_trueBothModes() {
        assertCase(term: false, ci: false, ppid: NORMAL, includeCI: true,  expected: true, "no TTY, gate mode")
        assertCase(term: false, ci: false, ppid: NORMAL, includeCI: false, expected: true, "no TTY, --setup mode")
    }

    /// Direct launchd child (`ppid == 1`) → non-interactive regardless of everything else.
    func testLaunchdChild_trueBothModes() {
        assertCase(term: true, ci: false, ppid: LAUNCHD, includeCI: true,  expected: true, "launchd, gate mode")
        assertCase(term: true, ci: false, ppid: LAUNCHD, includeCI: false, expected: true, "launchd, --setup mode")
        // ppid==1 dominates even with TTY present + CI excluded.
        assertCase(term: true, ci: true, ppid: LAUNCHD, includeCI: false, expected: true, "launchd dominates")
    }

    /// Combined signals still resolve to non-interactive (OR semantics).
    func testCombinedSignals_true() {
        assertCase(term: false, ci: true, ppid: LAUNCHD, includeCI: true,  expected: true, "all signals, gate mode")
        assertCase(term: false, ci: true, ppid: LAUNCHD, includeCI: false, expected: true, "all signals, --setup mode")
    }

    /// `EventKitManager.isNonInteractive` (the wired-up static) delegates to the helper —
    /// pin that the production seam reflects the current process env (gate mode, includeCI: true).
    func testEventKitManagerStaticMatchesHelper() {
        let expected = NonInteractiveDetection.isNonInteractive(
            env: ProcessInfo.processInfo.environment, ppid: getppid(), includeCI: true)
        XCTAssertEqual(EventKitManager.isNonInteractive, expected,
            "EventKitManager.isNonInteractive must delegate to NonInteractiveDetection (gate mode)")
    }
}
