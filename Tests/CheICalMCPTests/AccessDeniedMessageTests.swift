import EventKit
import XCTest

@testable import CheICalMCP

/// Pure-unit tests for `EventKitManager.accessDeniedMessage(...)` — the injectable
/// formatter behind `EventKitError.accessDenied`'s `errorDescription` (#158).
///
/// The point of #158 is the `deniedByStatus` branch: under the `.mcpb` install, when
/// TCC status was already `.denied` at the gate, a bare `--setup` cannot re-prompt (the
/// status-first check only requests on `.notDetermined`). The message must NOT lead with
/// `--setup` there — it must name the real blocker (anthropics/claude-code#63032) and the
/// paths that actually work (Claude Code plugin path, `tccutil reset`, `.ics` import).
final class AccessDeniedMessageTests: XCTestCase {

    private let hint = "\"/buried/path/CheICalMCP\" --setup"

    // MARK: - #154 dead-end signature (deniedByStatus + .mcpb) — the fix

    func testMCPBDeniedByStatus_doesNotLeadWithSetup() {
        let msg = EventKitManager.accessDeniedMessage(
            type: "Calendar", isSSH: false, isNonInteractive: false,
            isMCPB: true, deniedByStatus: true, setupHint: hint)

        // Must explicitly tell the user --setup will NOT fix this (the dead end).
        XCTAssertTrue(msg.contains("will NOT fix"),
            "the deniedByStatus/.mcpb message must state --setup does not fix the #154 state")
        // Must NOT present a bare `--setup` as step 1 (the misleading v1.11.0 text).
        XCTAssertFalse(msg.contains("1. \(hint)"),
            "step 1 must not be a bare `--setup` hint for the dead-end signature")
    }

    func testMCPBDeniedByStatus_namesRealBlockerAndSignature() {
        let msg = EventKitManager.accessDeniedMessage(
            type: "Calendar", isSSH: false, isNonInteractive: false,
            isMCPB: true, deniedByStatus: true, setupHint: hint)

        XCTAssertTrue(msg.contains("#154"), "must name the #154 signature")
        XCTAssertTrue(msg.contains("63032"),
            "must reference the real upstream blocker anthropics/claude-code#63032")
        XCTAssertTrue(msg.contains("csreq"), "must name the csreq mismatch mechanism")
    }

    func testMCPBDeniedByStatus_pointsAtWorkingAlternatives() {
        let msg = EventKitManager.accessDeniedMessage(
            type: "Calendar", isSSH: false, isNonInteractive: false,
            isMCPB: true, deniedByStatus: true, setupHint: hint)

        XCTAssertTrue(msg.contains("claude plugin install che-ical-mcp@psychquant-claude-plugins"),
            "must point at the working Claude Code plugin install path")
        XCTAssertTrue(msg.contains("tccutil reset Calendar com.checheng.CheICalMCP"),
            "must offer the reset-then-regrant heal, type-correct for Calendar")
        XCTAssertTrue(msg.contains(".ics"), "must mention the `.ics` import fallback")
    }

    func testMCPBDeniedByStatus_tccutilServiceTracksType() {
        // The tccutil service name must follow the entity type, not hardcode Calendar.
        let reminders = EventKitManager.accessDeniedMessage(
            type: "Reminders", isSSH: false, isNonInteractive: false,
            isMCPB: true, deniedByStatus: true, setupHint: hint)
        XCTAssertTrue(reminders.contains("tccutil reset Reminders com.checheng.CheICalMCP"),
            "Reminders denial must reset the Reminders service, not Calendar")
    }

    // MARK: - First-run .mcpb (notDetermined path) — --setup still IS the fix

    func testMCPBFirstRun_stillLeadsWithSetup() {
        // deniedByStatus:false = status was .notDetermined (or request couldn't present) →
        // `--setup` from a foreground Terminal genuinely re-prompts, so keep leading with it.
        let msg = EventKitManager.accessDeniedMessage(
            type: "Calendar", isSSH: false, isNonInteractive: false,
            isMCPB: true, deniedByStatus: false, setupHint: hint)

        XCTAssertTrue(msg.contains("1. \(hint)"),
            "first-run .mcpb message must still present `--setup` as step 1")
        XCTAssertTrue(msg.contains("58239"), "first-run message tracks #58239")
        XCTAssertFalse(msg.contains("#154"),
            "first-run message must not mislabel itself as the #154 dead end")
        XCTAssertFalse(msg.contains("will NOT fix"),
            "first-run message must not tell the user --setup fails")
    }

    // MARK: - Regression: other branches unchanged by the refactor

    func testSSHBranch_unchanged() {
        let msg = EventKitManager.accessDeniedMessage(
            type: "Calendar", isSSH: true, isNonInteractive: false,
            isMCPB: false, deniedByStatus: false, setupHint: hint)
        XCTAssertTrue(msg.contains("SSH session detected"))
        XCTAssertTrue(msg.contains("Full Disk Access"))
    }

    func testSSHNonInteractiveBranch_unchanged() {
        let msg = EventKitManager.accessDeniedMessage(
            type: "Calendar", isSSH: true, isNonInteractive: true,
            isMCPB: false, deniedByStatus: false, setupHint: hint)
        XCTAssertTrue(msg.contains("SSH + non-interactive session detected"))
    }

    func testNonInteractiveBranch_usesInjectedHint() {
        let msg = EventKitManager.accessDeniedMessage(
            type: "Reminders", isSSH: false, isNonInteractive: true,
            isMCPB: false, deniedByStatus: false, setupHint: hint)
        XCTAssertTrue(msg.contains("non-interactive session detected"))
        XCTAssertTrue(msg.contains(hint), "non-interactive message uses the injected setup hint")
    }

    func testGenericBranch_unchanged() {
        let msg = EventKitManager.accessDeniedMessage(
            type: "Calendar", isSSH: false, isNonInteractive: false,
            isMCPB: false, deniedByStatus: false, setupHint: hint)
        XCTAssertTrue(msg.contains("Open System Settings → Privacy & Security → Calendar"))
        XCTAssertTrue(msg.contains(hint))
    }

    // SSH takes precedence over deniedByStatus (an SSH denial is not the #154 signature).
    func testSSHPrecedesDeniedByStatus() {
        let msg = EventKitManager.accessDeniedMessage(
            type: "Calendar", isSSH: true, isNonInteractive: false,
            isMCPB: true, deniedByStatus: true, setupHint: hint)
        XCTAssertTrue(msg.contains("SSH session detected"),
            "SSH branch must win over the #154 branch")
        XCTAssertFalse(msg.contains("#154"))
    }
}
