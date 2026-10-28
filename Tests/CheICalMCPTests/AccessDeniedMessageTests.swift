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

    // MARK: - #343: the generic branch names the process macOS checks

    private func generic(_ attribution: ResponsibleHostKind?) -> String {
        EventKitManager.accessDeniedMessage(
            type: "Calendar", isSSH: false, isNonInteractive: false,
            isMCPB: false, deniedByStatus: false, setupHint: hint, attribution: attribution)
    }

    func testGenericBranch_withoutAttribution_doesNotBlameTerminal() {
        // The old line "Enable access for the MCP server or Terminal" named neither of the
        // processes macOS checked under the Claude Code daemon (#343).
        let msg = generic(nil)
        XCTAssertFalse(msg.contains("for the MCP server or Terminal"))
        XCTAssertTrue(msg.contains("--print-tcc-path"), "point at the tool that shows which process macOS checks")
    }

    func testSelfAttribution_leadsWithItsOwnGrantAndSetup() {
        let msg = generic(.selfBinary)
        XCTAssertTrue(msg.contains("CheICalMCP's own grant"))
        XCTAssertTrue(msg.contains("1. Allow the macOS prompt for CheICalMCP, or run its setup from Terminal: \(hint)"))
    }

    func testClaudeCodeAttribution_explainsItCannotBePrompted_andGivesTheSharedRemedy() {
        let msg = generic(.claudeCode(version: "2.1.309"))
        XCTAssertTrue(msg.contains("no Calendar or Reminders purpose string"))
        XCTAssertTrue(msg.contains("CHE_ICAL_MCP_NO_DISCLAIM"))
        XCTAssertTrue(msg.contains("CHE_ICAL_MCP_DISCLAIMED"))
        XCTAssertFalse(msg.contains("Remove CHE_ICAL_MCP_NO_DISCLAIM"),
                       "the opt-out may never have been set: the re-exec can also have failed or been skipped")
        // Status-aware rule: after a restart a host without access re-execs, so the grant
        // `--setup` creates is the one that serves it.
        XCTAssertTrue(msg.contains("Restart the MCP client"))
        XCTAssertTrue(msg.contains(hint))
    }

    func testAppAttribution_namesTheApp() {
        let msg = generic(.appBundle(name: "Visual Studio Code"))
        XCTAssertTrue(msg.contains("enable Visual Studio Code"))
        XCTAssertFalse(msg.contains("unset CHE_ICAL_MCP_NO_DISCLAIM"))
        // Round 2 row 1: `--setup` alone did not help a host that was never re-executed. With
        // the status-aware rule it does, after a restart — the message has to say so.
        XCTAssertTrue(msg.contains("Restart the MCP client"))
        XCTAssertTrue(msg.contains(hint), "--setup is how CheICalMCP gets its own grant under any host")
    }

    func testOtherExecutableAttribution_givesTheSharedRemedy() {
        let msg = generic(.otherExecutable(path: "/sbin/launchd"))
        XCTAssertTrue(msg.contains("Restart the MCP client"))
        XCTAssertTrue(msg.contains(hint))
        XCTAssertTrue(msg.contains("--print-tcc-path"))
    }

    func testAppNameOutsideTheSafeSet_isNotEchoedIntoTheResponse() {
        // The bundle name comes from a path anyone can create, and this message is returned to
        // an MCP client. Round 2 row 9: escaping control characters alone let any text through.
        let long = String(repeating: "A", count: 200)
        for name in [long, "Evil`whoami`", "Tool\"; rm -rf ~; \""] {
            let msg = generic(.appBundle(name: name))
            XCTAssertFalse(msg.contains(name), "name \(name.prefix(20))")
            XCTAssertTrue(msg.contains("the app that launched this server"))
        }
        XCTAssertTrue(generic(.appBundle(name: "ターミナル")).contains("enable ターミナル"))
    }

    func testRestrictedByPolicy_namesThePolicyAndOffersNoPromptOrSwitch() {
        // `.restricted` is a configuration profile or Screen Time, not a recorded "Don't Allow":
        // neither a prompt nor the System Settings switch can change it (round 2 row 9).
        for mcpb in [false, true] {
            let msg = EventKitManager.accessDeniedMessage(
                type: "Calendar", isSSH: false, isNonInteractive: false,
                isMCPB: mcpb, deniedByStatus: true, setupHint: hint, attribution: .selfBinary,
                restrictedByPolicy: true)
            XCTAssertTrue(msg.contains("restricted"))
            XCTAssertTrue(msg.contains("configuration profile"))
            XCTAssertFalse(msg.contains("Allow the macOS prompt"))
            XCTAssertFalse(msg.contains(hint))
            XCTAssertFalse(msg.contains("tccutil"))
        }
    }

    func testSelfAttributionAlreadyDenied_doesNotPromiseAPrompt() {
        // Once the user pressed "Don't Allow" the status is .denied: no prompt will appear
        // and --setup cannot re-prompt (the #154 / #158 dead end), so the first step must
        // be the System Settings switch, not "allow the prompt".
        let msg = EventKitManager.accessDeniedMessage(
            type: "Calendar", isSSH: false, isNonInteractive: false,
            isMCPB: false, deniedByStatus: true, setupHint: hint, attribution: .selfBinary)
        XCTAssertFalse(msg.contains("Allow the macOS prompt"))
        XCTAssertTrue(msg.contains("System Settings → Privacy & Security → Calendar"))
        // Round 2 row 9: `tccutil reset … com.checheng.CheICalMCP` fails with -10814 for a bare
        // binary (README erratum), so it is not offered as a fix.
        XCTAssertFalse(msg.contains("tccutil reset Calendar com.checheng.CheICalMCP"))
    }

    func testAttribution_doesNotOverrideTheSSHBranch() {
        let msg = EventKitManager.accessDeniedMessage(
            type: "Calendar", isSSH: true, isNonInteractive: false,
            isMCPB: false, deniedByStatus: false, setupHint: hint, attribution: .selfBinary)
        XCTAssertTrue(msg.contains("SSH session detected"))
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
