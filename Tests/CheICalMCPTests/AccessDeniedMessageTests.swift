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
    private let diagnose = "'/buried/path/CheICalMCP' --print-tcc-path"

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
            isMCPB: true, deniedByStatus: true, setupHint: hint, printTCCPathHint: diagnose)

        XCTAssertTrue(msg.contains("claude plugin install che-ical-mcp@psychquant-claude-plugins"),
            "must point at the working Claude Code plugin install path")
        // #357 (deliberate change to the #158 pin) and round-2 policy P1/P4: text returned to
        // the model carries no reset; a person at the Mac runs --print-tcc-path for the steps,
        // and --setup is not offered for an already-denied status.
        TCCRemedyAssertions.assertMCPFacingStaleGrant(msg)
        XCTAssertTrue(msg.contains(diagnose), "the diagnose command for this binary: \(msg)")
        XCTAssertFalse(msg.contains(hint), "--setup prompts only from notDetermined: \(msg)")
        XCTAssertTrue(msg.contains(".ics"), "must mention the `.ics` import fallback")
    }

    func testMCPBDeniedByStatus_settingsPaneTracksType() {
        // The System Settings pane must follow the entity type, not hardcode Calendar.
        let reminders = EventKitManager.accessDeniedMessage(
            type: "Reminders", isSSH: false, isNonInteractive: false,
            isMCPB: true, deniedByStatus: true, setupHint: hint, printTCCPathHint: diagnose)
        XCTAssertTrue(reminders.contains("Reminders access denied"), reminders)
        XCTAssertFalse(reminders.contains("Calendar access"), reminders)
        TCCRemedyAssertions.assertMCPFacingStaleGrant(reminders)
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
                        TCCRemedyAssertions.assertNoBundleIDResetAndNoButton(msg)
                    }
                } } }
            } }
        }
    }

    func testUnknownAuthStateMessage_sendsAPersonAtTheMacToPrintTCCPath() {
        // Round-2 policy P1: no reset in text returned to the model.
        let msg = EventKitError.unknownAuthState(type: "Calendar", statusValue: 99).errorDescription ?? ""
        TCCRemedyAssertions.assertMCPFacingStaleGrant(msg)
        XCTAssertTrue(msg.contains("' --print-tcc-path"), "names this binary's command: \(msg)")
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
        // #357 verify: the pane has no + button; an app is listed once it requests access.
        XCTAssertFalse(msg.contains("manually add"), msg)
        XCTAssertTrue(msg.contains("if it is not listed, step 1 adds it"), msg)
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

    // MARK: - #362: the SSH text follows the attribution (round-2 policy P1, P4, P5)

    private func ssh(_ attribution: ResponsibleHostKind?, nonInteractive: Bool = false,
                     denied: Bool = false, noDisclaimSet: Bool = false) -> String {
        EventKitManager.accessDeniedMessage(
            type: "Calendar", isSSH: true, isNonInteractive: nonInteractive,
            isMCPB: false, deniedByStatus: denied, setupHint: hint, attribution: attribution,
            printTCCPathHint: diagnose, noDisclaimSet: noDisclaimSet)
    }

    private func steps(_ msg: String) -> [String] {
        msg.components(separatedBy: "\n").filter { $0.first?.isNumber == true }
    }

    private let fullDiskAccess = "Grant Full Disk Access to /usr/sbin/sshd"
    private let sshdHost = ResponsibleHostKind.otherExecutable(path: "/usr/sbin/sshd")

    /// Self-attributed: CheICalMCP's own grant, the local `--setup` only for a not-yet-asked
    /// status (P4), and no sshd step: the responsible host is not sshd (P5).
    func testSSH_selfAttribution_ownGrantLocalSetup_noSshdStep() {
        for nonInteractive in [false, true] {
            let msg = ssh(.selfBinary, nonInteractive: nonInteractive)
            XCTAssertTrue(msg.contains("CheICalMCP's own grant"), msg)
            XCTAssertTrue(msg.contains(hint), msg)
            XCTAssertTrue(msg.contains("prompts only while the status is notDetermined"), msg)
            XCTAssertTrue(msg.contains("not over SSH"), msg)
            XCTAssertFalse(msg.contains("Full Disk Access"), msg)
            XCTAssertFalse(msg.contains("does not carry privacy permissions to SSH sessions"), msg)
        }
        XCTAssertTrue(ssh(.selfBinary, nonInteractive: true).contains("non-interactive job"))
    }

    func testSSH_selfAttributionAlreadyDenied_offersTheSwitch() {
        let msg = ssh(.selfBinary, denied: true)
        XCTAssertTrue(msg.contains("Don't Allow"), msg)
        XCTAssertTrue(msg.contains("switch CheICalMCP on"), msg)
        XCTAssertFalse(msg.contains(hint), msg)
    }

    /// P5: the host branch's cause list is the one ResponsibleProcessFormatter uses.
    func testSSH_hostAttribution_causesComeFromTheSharedSource() {
        let causes = ResponsibleProcessFormatter.noReexecCauses(host: "the process macOS checks")
        for marker in ["CHE_ICAL_MCP_NO_DISCLAIM is set", "CHE_ICAL_MCP_DISCLAIMED was inherited",
                       "the re-exec failed", "a policy restricts", "lost it since"] {
            XCTAssertTrue(causes.contains(marker), marker)
        }
        for host in [ResponsibleHostKind.appBundle(name: "Visual Studio Code"), sshdHost, .unknown] {
            XCTAssertTrue(ssh(host).contains(causes), ssh(host))
        }
        XCTAssertTrue(ResponsibleProcessFormatter.advice(for: .claudeCode(version: "2.1.309"))
            .contains(ResponsibleProcessFormatter.noReexecCauses(host: "Claude Code 2.1.309")))
    }

    /// P5: removing CHE_ICAL_MCP_NO_DISCLAIM is offered only when it is set.
    func testSSH_hostAttribution_noDisclaimStepOnlyWhenSet() {
        let host = ResponsibleHostKind.appBundle(name: "Visual Studio Code")
        XCTAssertFalse(ssh(host).contains("remove CHE_ICAL_MCP_NO_DISCLAIM"), ssh(host))
        let set = ssh(host, noDisclaimSet: true)
        XCTAssertTrue(set.contains("remove CHE_ICAL_MCP_NO_DISCLAIM"), set)
        XCTAssertTrue(set.contains(hint), "re-exec route: the local --setup: \(set)")
        XCTAssertTrue(set.contains("prompts only while the status is notDetermined"), set)
        let deniedSet = ssh(host, denied: true, noDisclaimSet: true)
        XCTAssertFalse(deniedSet.contains(hint), "denied: the switch, not --setup: \(deniedSet)")
    }

    /// P5: a named app host gets "grant that app", as the non-SSH host remedy does; no sshd step.
    func testSSH_appHost_grantsTheApp_noSshdStep() {
        let msg = ssh(.appBundle(name: "Visual Studio Code"))
        XCTAssertTrue(msg.contains("enable Visual Studio Code for both Calendar and Reminders"), msg)
        XCTAssertFalse(msg.contains("Full Disk Access"), msg)
    }

    /// P5: the sshd step only when the responsible host is sshd or unknown, with its warning.
    func testSSH_sshdOrUnknownHost_leadsWithSshdFullDiskAccess() {
        for host in [sshdHost, .unknown, .otherExecutable(path: "/usr/libexec/sshd-session")] {
            for nonInteractive in [false, true] {
                let msg = ssh(host, nonInteractive: nonInteractive)
                XCTAssertTrue(msg.contains(nonInteractive ? "SSH + non-interactive session detected" : "SSH session detected"), msg)
                XCTAssertTrue(steps(msg).first?.contains(fullDiskAccess) == true, msg)
                XCTAssertTrue(msg.contains("only on a Mac you fully control"), msg)
                XCTAssertFalse(msg.contains("Run CheICalMCP once LOCALLY first"), msg)
            }
        }
    }

    /// P5: another named executable gets no sshd step, and its path is not echoed.
    func testSSH_otherExecutableHost_noSshdStep_pathNotEchoed() {
        let msg = ssh(.otherExecutable(path: "/opt/x/hostbin"))
        XCTAssertFalse(msg.contains("Full Disk Access"), msg)
        XCTAssertFalse(msg.contains("/opt/x/hostbin"), msg)
        XCTAssertFalse(msg.contains("hostbin"), msg)
        XCTAssertTrue(msg.contains("--print-tcc-path"), msg)
    }

    /// P4: denied with a host → lead with the switch.
    func testSSH_deniedHost_leadsWithTheSwitch() {
        for host: ResponsibleHostKind? in [sshdHost, .unknown, nil] {
            let msg = ssh(host, denied: true)
            XCTAssertTrue(steps(msg).first?.contains("switch it on") == true, msg)
        }
        let app = ssh(.appBundle(name: "Visual Studio Code"), denied: true)
        XCTAssertTrue(steps(app).first?.contains("switch Visual Studio Code on") == true, app)
    }

    /// P5: nil attribution = the kernel lookup was unavailable, so no re-exec happened.
    func testSSH_unknownAttribution_saysNoReexecHappened() {
        for nonInteractive in [false, true] {
            let msg = ssh(nil, nonInteractive: nonInteractive)
            XCTAssertTrue(msg.contains("lookup was unavailable"), msg)
            XCTAssertTrue(msg.contains("was not re-executed"), msg)
            XCTAssertFalse(msg.contains("default"), msg)
            XCTAssertTrue(msg.contains(fullDiskAccess), msg)
            XCTAssertTrue(msg.contains("only on a Mac you fully control"), msg)
        }
    }

    /// P1: no SSH text carries a reset.
    func testSSH_noBranchCarriesAReset() {
        for host: ResponsibleHostKind? in [nil, .selfBinary, .claudeCode(version: "2.1.309"),
                                           .appBundle(name: "Visual Studio Code"), sshdHost, .unknown] {
            for denied in [false, true] { for set in [false, true] {
                XCTAssertFalse(ssh(host, denied: denied, noDisclaimSet: set).contains("tccutil"))
            } }
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
