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
/// paths that actually work (Claude Code plugin path, removing the stale System Settings
/// entry before `--setup`, `.ics` import). `tccutil reset <service> com.checheng.CheICalMCP`
/// was step 2 until #357: it fails with -10814 for a bare binary (no LaunchServices record).
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
        // #357 (deliberate change to the #158 pin): the heal is removing the stale row in
        // System Settings with the − button, then `--setup`; `tccutil reset <service>
        // com.checheng.CheICalMCP` fails with -10814 for a bare binary and is no longer offered.
        XCTAssertFalse(msg.contains("tccutil"), "the -10814 command must not be offered: \(msg)")
        XCTAssertTrue(msg.contains("System Settings → Privacy & Security → Calendar"),
            "must point at the Calendar pane, type-correct")
        XCTAssertTrue(msg.contains("− button"), "must say to remove the stale entry, not only toggle it")
        XCTAssertTrue(msg.contains("then re-run \(hint)"), "the re-grant is this binary's --setup")
        XCTAssertTrue(msg.contains(".ics"), "must mention the `.ics` import fallback")
    }

    func testMCPBDeniedByStatus_settingsPaneTracksType() {
        // The System Settings pane must follow the entity type, not hardcode Calendar.
        let reminders = EventKitManager.accessDeniedMessage(
            type: "Reminders", isSSH: false, isNonInteractive: false,
            isMCPB: true, deniedByStatus: true, setupHint: hint)
        XCTAssertTrue(reminders.contains("System Settings → Privacy & Security → Reminders"),
            "Reminders denial must point at the Reminders pane")
        XCTAssertFalse(reminders.contains("Privacy & Security → Calendar"))
    }

    // MARK: - #357: no surface offers `tccutil reset`

    /// `tccutil reset <service> com.checheng.CheICalMCP` fails with -10814 for a bare binary,
    /// and a bare `tccutil reset Calendar` wipes every app's grant: no branch may offer either.
    func testNoAccessDeniedBranchOffersTccutil() {
        let attributions: [ResponsibleHostKind?] = [
            nil, .selfBinary, .claudeCode(version: "2.1.309"), .appBundle(name: "Visual Studio Code"),
            .otherExecutable(path: "/sbin/launchd"), .unknown]
        for type in ["Calendar", "Reminders"] {
            for ssh in [false, true] { for nonInteractive in [false, true] {
                for mcpb in [false, true] { for denied in [false, true] { for restricted in [false, true] {
                    for attribution in attributions {
                        let msg = EventKitManager.accessDeniedMessage(
                            type: type, isSSH: ssh, isNonInteractive: nonInteractive, isMCPB: mcpb,
                            deniedByStatus: denied, setupHint: hint, attribution: attribution,
                            restrictedByPolicy: restricted)
                        XCTAssertFalse(msg.contains("tccutil"), msg)
                    }
                } } }
            } }
        }
    }

    func testUnknownAuthStateMessage_offersNoTccutil() {
        let msg = EventKitError.unknownAuthState(type: "Calendar", statusValue: 99).errorDescription ?? ""
        XCTAssertFalse(msg.contains("tccutil"), msg)
        XCTAssertTrue(msg.contains("System Settings → Privacy & Security"), msg)
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

    func testAppNameLength_isCountedInScalars() {
        // Verify round 3 row 22: 40 "e + combining acute" pairs are 40 characters but 80 scalars;
        // counting characters let combining marks stretch a name past the bound.
        XCTAssertNil(ResponsibleProcessFormatter.responseSafeAppName(String(repeating: "e\u{0301}", count: 40)))
        XCTAssertEqual(ResponsibleProcessFormatter.responseSafeAppName("Visual Studio Code"), "Visual Studio Code")
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

    func testRestrictedByPolicy_asksForAccessForTheProcessMacOSChecks() {
        // #367: a restricted host keeps its attribution, so the policy has to allow the host;
        // allowing CheICalMCP would not change what macOS checks.
        func msg(_ attribution: ResponsibleHostKind?) -> String {
            EventKitManager.accessDeniedMessage(
                type: "Calendar", isSSH: false, isNonInteractive: false, isMCPB: false,
                deniedByStatus: true, setupHint: hint, attribution: attribution, restrictedByPolicy: true)
        }
        XCTAssertTrue(msg(.selfBinary).contains("Calendar access for CheICalMCP"))
        let app = msg(.appBundle(name: "Visual Studio Code"))
        XCTAssertTrue(app.contains("Calendar access for Visual Studio Code"), app)
        XCTAssertFalse(app.contains("access for CheICalMCP"), app)
        XCTAssertTrue(msg(.claudeCode(version: "2.1.309")).contains("Calendar access for Claude Code"))
        for unnamed: ResponsibleHostKind? in [.otherExecutable(path: "/tmp/x"), .unknown, nil,
                                             .appBundle(name: "bad\u{1B}name")] {
            let m = msg(unnamed)
            XCTAssertTrue(m.contains("--print-tcc-path"), m)
            XCTAssertFalse(m.contains("/tmp/x"), "a path is not echoed to the client")
            XCTAssertFalse(m.unicodeScalars.contains { $0.value == 0x1B })
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

    // MARK: - #362: the SSH text follows the attribution

    private func ssh(_ attribution: ResponsibleHostKind?, nonInteractive: Bool = false,
                     denied: Bool = false) -> String {
        EventKitManager.accessDeniedMessage(
            type: "Calendar", isSSH: true, isNonInteractive: nonInteractive,
            isMCPB: false, deniedByStatus: denied, setupHint: hint, attribution: attribution)
    }

    /// Under the status-aware rule (#343) an ssh context without full access re-execs, so
    /// macOS checks CheICalMCP's own grant: the text names it and gives the local `--setup`.
    func testSSH_selfAttribution_namesCheICalMCPsOwnGrantAndTheLocalSetup() {
        for nonInteractive in [false, true] {
            let msg = ssh(.selfBinary, nonInteractive: nonInteractive)
            XCTAssertTrue(msg.contains("SSH"), msg)
            XCTAssertTrue(msg.contains("CheICalMCP's own grant"), msg)
            XCTAssertTrue(msg.contains(hint), "the local --setup for this binary: \(msg)")
            XCTAssertTrue(msg.contains("not over SSH"), msg)
            XCTAssertTrue(msg.contains("System Settings → Privacy & Security → Calendar"), msg)
            XCTAssertFalse(msg.contains("does not carry privacy permissions to SSH sessions"),
                "the stale pre-#343 reason must not be given when CheICalMCP is checked: \(msg)")
        }
        XCTAssertTrue(ssh(.selfBinary, nonInteractive: true).contains("non-interactive job"))
    }

    /// Whether sshd's Full Disk Access is still needed with CheICalMCP's own grant was not
    /// measured (no ssh login in the #362 run), so the step stays, as a last resort only.
    func testSSH_selfAttribution_keepsTheSshdStepOnlyAsALastResort() {
        let msg = ssh(.selfBinary)
        XCTAssertTrue(msg.contains("Full Disk Access"), msg)
        XCTAssertTrue(msg.contains("still denied"), msg)
        XCTAssertTrue(msg.contains("broad file access"), "the existing warning stays: \(msg)")
    }

    func testSSH_selfAttributionAlreadyDenied_offersTheSwitch() {
        let msg = ssh(.selfBinary, denied: true)
        XCTAssertTrue(msg.contains("Don't Allow"), msg)
        XCTAssertTrue(msg.contains("switch CheICalMCP on"), msg)
    }

    /// A host keeps its attribution over ssh (`CHE_ICAL_MCP_NO_DISCLAIM`, a failed re-exec):
    /// the host steps stay as they were.
    func testSSH_hostOrUnknownAttribution_keepsTheHostSteps() {
        let hosts: [ResponsibleHostKind?] = [nil, .claudeCode(version: "2.1.309"),
                                             .appBundle(name: "Visual Studio Code"), .otherExecutable(path: "/usr/sbin/sshd"), .unknown]
        for host in hosts {
            let msg = ssh(host)
            XCTAssertTrue(msg.contains("SSH session detected"), msg)
            XCTAssertTrue(msg.contains("Full Disk Access"), msg)
            XCTAssertFalse(msg.contains("CheICalMCP's own grant"), msg)
            XCTAssertTrue(ssh(host, nonInteractive: true).contains("SSH + non-interactive session detected"))
        }
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
