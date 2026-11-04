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
/// paths that actually work (Claude Code plugin path, switching the stale System Settings
/// entry off and on before `--setup`, `.ics` import). `tccutil reset <service>
/// com.checheng.CheICalMCP` was step 2 until #357: it fails with -10814 for a bare binary (no
/// LaunchServices record); the bare `tccutil reset <service>` stays only as the last resort.
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
        // #357 (deliberate change to the #158 pin): the heal is switching the stale row off and
        // on in System Settings (the pane has no − button, verify round), then `--setup`;
        // `tccutil reset <service> com.checheng.CheICalMCP` fails with -10814 for a bare binary.
        TCCRemedyAssertions.assertStaleGrantRemedy(msg, service: "Calendar")
        XCTAssertTrue(msg.contains("System Settings → Privacy & Security → Calendar"),
            "must point at the Calendar pane, type-correct")
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
        TCCRemedyAssertions.assertStaleGrantRemedy(reminders, service: "Reminders")
    }

    // MARK: - #357: no surface offers `tccutil reset` with the bundle id

    /// `tccutil reset <service> com.checheng.CheICalMCP` fails with -10814 for a bare binary;
    /// a bare `tccutil reset <service>` clears every app's grant, so it may appear only as the
    /// last resort with that consequence stated; and the pane has no − button.
    func testNoAccessDeniedBranchOffersABundleIDResetOrAMinusButton() {
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
                        TCCRemedyAssertions.assertNoBundleIDResetAndNoMinusButton(msg)
                    }
                } } }
            } }
        }
    }

    func testUnknownAuthStateMessage_givesTheStaleGrantRemedy() {
        let msg = EventKitError.unknownAuthState(type: "Calendar", statusValue: 99).errorDescription ?? ""
        TCCRemedyAssertions.assertStaleGrantRemedy(msg, service: "Calendar")
        XCTAssertTrue(msg.contains("System Settings → Privacy & Security → Calendar"), msg)
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
        XCTAssertTrue(msg.contains("only on a Mac you fully control"), "verify LOW (#362): warning on every sshd step")
    }

    func testSSHNonInteractiveBranch_unchanged() {
        let msg = EventKitManager.accessDeniedMessage(
            type: "Calendar", isSSH: true, isNonInteractive: true,
            isMCPB: false, deniedByStatus: false, setupHint: hint)
        XCTAssertTrue(msg.contains("SSH + non-interactive session detected"))
        XCTAssertTrue(msg.contains("only on a Mac you fully control"), "verify LOW (#362): warning on every sshd step")
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

    /// #362: the attribution decides the SSH text, and the SSH context is still named. A
    /// self-attributed ssh denial no longer gets the pre-#343 SSH text.
    func testSSHText_followsTheAttribution_andStillNamesTheSSHContext() {
        let selfMsg = EventKitManager.accessDeniedMessage(
            type: "Calendar", isSSH: true, isNonInteractive: false,
            isMCPB: false, deniedByStatus: false, setupHint: hint, attribution: .selfBinary)
        XCTAssertTrue(selfMsg.contains("SSH session detected"), selfMsg)
        XCTAssertTrue(selfMsg.contains("CheICalMCP's own grant"), selfMsg)
        XCTAssertFalse(selfMsg.contains("does not carry privacy permissions to SSH sessions"), selfMsg)
        let hostMsg = EventKitManager.accessDeniedMessage(
            type: "Calendar", isSSH: true, isNonInteractive: false, isMCPB: false,
            deniedByStatus: false, setupHint: hint, attribution: .appBundle(name: "Visual Studio Code"))
        XCTAssertNotEqual(selfMsg, hostMsg)
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
        XCTAssertTrue(msg.contains("still refused"), msg)
        XCTAssertTrue(msg.contains("untested"), "say the step is untested for this attribution: \(msg)")
        XCTAssertTrue(msg.contains("only on a Mac you fully control"), "the existing warning stays: \(msg)")
    }

    func testSSH_selfAttributionAlreadyDenied_offersTheSwitch() {
        let msg = ssh(.selfBinary, denied: true)
        XCTAssertTrue(msg.contains("Don't Allow"), msg)
        XCTAssertTrue(msg.contains("switch CheICalMCP on"), msg)
    }

    /// #362 verify: a host keeps its attribution over ssh (`CHE_ICAL_MCP_NO_DISCLAIM`, a failed
    /// re-exec), where a local `--setup` grant is not the one macOS checks. The text leads with
    /// sshd's Full Disk Access, with its warning, and says when a local `--setup` applies.
    func testSSH_hostAttribution_leadsWithSshdFullDiskAccess() {
        let hosts: [ResponsibleHostKind] = [.claudeCode(version: "2.1.309"),
                                            .appBundle(name: "Visual Studio Code"),
                                            .otherExecutable(path: "/usr/sbin/sshd"), .unknown]
        for host in hosts {
            for nonInteractive in [false, true] {
                let msg = ssh(host, nonInteractive: nonInteractive)
                XCTAssertTrue(msg.contains(nonInteractive ? "SSH + non-interactive session detected" : "SSH session detected"), msg)
                XCTAssertTrue(msg.contains("1. Grant Full Disk Access to /usr/sbin/sshd"), msg)
                XCTAssertTrue(msg.contains("only on a Mac you fully control"), msg)
                XCTAssertTrue(msg.contains("CHE_ICAL_MCP_NO_DISCLAIM"), msg)
                XCTAssertTrue(msg.contains("only when this ssh process re-executes onto CheICalMCP"), msg)
                XCTAssertFalse(msg.contains("Run CheICalMCP once LOCALLY first"), msg)
                XCTAssertFalse(msg.contains("/usr/sbin/sshd/"), "a host path is not echoed: \(msg)")
            }
        }
    }

    /// #362 verify: with the kernel lookup unavailable, it is unknown which grant macOS checks,
    /// so the text gives both cases.
    func testSSH_unknownAttribution_givesBothCases() {
        for nonInteractive in [false, true] {
            let msg = ssh(nil, nonInteractive: nonInteractive)
            XCTAssertTrue(msg.contains("SSH"), msg)
            XCTAssertTrue(msg.contains("If this ssh process re-executed onto CheICalMCP"), msg)
            XCTAssertTrue(msg.contains(hint), msg)
            XCTAssertTrue(msg.contains("If it kept the ssh context's attribution"), msg)
            XCTAssertTrue(msg.contains("Full Disk Access to /usr/sbin/sshd"), msg)
            XCTAssertTrue(msg.contains("only on a Mac you fully control"), msg)
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
