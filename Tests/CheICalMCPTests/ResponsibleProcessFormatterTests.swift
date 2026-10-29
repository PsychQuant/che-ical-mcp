import XCTest
@testable import CheICalMCP

/// Coverage for `ResponsibleProcessFormatter` (#343) — the `--print-tcc-path` attribution
/// block and the per-kind advice the banner and access-denied message reuse. The advice
/// must name the client macOS actually checks; naming the parent chain's host instead is
/// the misdirection #343 was filed for.
final class ResponsibleProcessFormatterTests: XCTestCase {

    func testSelfBinary_marksThisBinaryAndNamesItsOwnGrant() {
        let s = ResponsibleProcessFormatter.attributionSection(
            selfPid: 500,
            result: .resolved(ResponsibleProcess(pid: 500, path: "/Users/u/bin/CheICalMCP", isSelf: true)))
        XCTAssertTrue(s.contains("TCC attribution"))
        XCTAssertTrue(s.contains("500  /Users/u/bin/CheICalMCP  (this binary)"))
        XCTAssertTrue(s.contains("CheICalMCP's own grant"))
    }

    func testAppBundleHost_namesTheApp() {
        let s = ResponsibleProcessFormatter.attributionSection(
            selfPid: 500,
            result: .resolved(ResponsibleProcess(
                pid: 3599, path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", isSelf: false)))
        XCTAssertTrue(s.contains("3599  /Applications/Visual Studio Code.app/Contents/MacOS/Electron"))
        XCTAssertFalse(s.contains("(this binary)"))
        XCTAssertTrue(s.contains("Visual Studio Code's grant"))
    }

    func testClaudeCodeHost_explainsItCannotBePromptedAndHowToFix() {
        let advice = ResponsibleProcessFormatter.advice(for: .claudeCode(version: "2.1.309"))
        XCTAssertTrue(advice.contains("Claude Code 2.1.309"))
        XCTAssertTrue(advice.contains("no Calendar or Reminders purpose string"))
        // Under Claude Code the process was NOT re-executed — the opt-out is one of three
        // causes, and the advice must not blame it when it was never set (verify of PR #347).
        XCTAssertTrue(advice.contains("CHE_ICAL_MCP_NO_DISCLAIM"))
        XCTAssertTrue(advice.contains("CHE_ICAL_MCP_DISCLAIMED"))
        XCTAssertTrue(advice.contains("re-exec failed"))
        XCTAssertFalse(advice.contains("Unset CHE_ICAL_MCP_NO_DISCLAIM"))
        // Status-aware rule: a Claude Code host with full access is kept, so a host-attributed
        // denial can also mean the grant changed after start-up.
        XCTAssertTrue(advice.contains("lost it since"))
    }

    func testUnavailable_rendersTheReason() {
        let s = ResponsibleProcessFormatter.attributionSection(
            selfPid: 500, result: .unavailable(reason: "responsibility SPI not found in this macOS"))
        XCTAssertTrue(s.contains("(responsible process unavailable: responsibility SPI not found in this macOS)"))
    }

    func testMissingPath_isVisible() {
        let s = ResponsibleProcessFormatter.attributionSection(
            selfPid: 500, result: .resolved(ResponsibleProcess(pid: 77, path: nil, isSelf: false)))
        XCTAssertTrue(s.contains("77  (no path reported)"))
    }

    // MARK: - --setup authorization target (#343)

    func testSetupTarget_self_namesCheICalMCPAndThePath() {
        let line = ResponsibleProcessFormatter.setupTargetLine(
            .resolved(ResponsibleProcess(pid: 500, path: "/Users/u/bin/CheICalMCP", isSelf: true)))
        XCTAssertTrue(line.hasPrefix("Authorization target: CheICalMCP (/Users/u/bin/CheICalMCP)"))
        XCTAssertFalse(line.contains("WARNING"))
    }

    func testSetupTarget_self_saysWhichHostsUseTheGrant() {
        // Round 2 row 3: "every host that launches this binary uses this grant" was false —
        // a host with full access of its own keeps it.
        let line = ResponsibleProcessFormatter.setupTargetLine(
            .resolved(ResponsibleProcess(pid: 500, path: "/Users/u/bin/CheICalMCP", isSelf: true)))
        XCTAssertFalse(line.contains("every host"))
        XCTAssertTrue(line.contains("has no full Calendar and Reminders access of its own"))
        // Verify round 3 row 19: the criterion is the responsible process, not the launcher.
        XCTAssertTrue(line.contains("responsible process"))
        XCTAssertFalse(line.contains("the process that launches"))
    }

    // MARK: - Shared remedy for a host-attributed denial (#343 verify round 2, row 1)

    func testHostAttributedRemedy_restartsAndPointsAtCheICalMCPsOwnGrant() {
        let steps = ResponsibleProcessFormatter.hostAttributedRemedy(
            setupCommand: "'/Users/u/bin/CheICalMCP' --setup", settingsPane: "Calendar", alsoEnable: nil)
        XCTAssertEqual(steps.count, 3)
        XCTAssertTrue(steps[0].contains("Restart the MCP client"))
        XCTAssertTrue(steps[0].contains("CHE_ICAL_MCP_NO_DISCLAIM"))
        XCTAssertTrue(steps[1].contains("'/Users/u/bin/CheICalMCP' --setup"))
        XCTAssertTrue(steps[1].contains("CheICalMCP's own grant"))
    }

    func testHostAttributedRemedy_namesEveryReasonTheReexecDidNotHappen() {
        // Verify round 3 row 8: only NO_DISCLAIM was named, but an inherited sentinel and a
        // failed re-exec leave the same state, and a restart fixes neither.
        let steps = ResponsibleProcessFormatter.hostAttributedRemedy(
            setupCommand: "'x' --setup", settingsPane: "Calendar", alsoEnable: nil)
        XCTAssertTrue(steps[0].contains("CHE_ICAL_MCP_DISCLAIMED"))
        XCTAssertTrue(steps[0].contains("could not re-exec"))
    }

    func testHostAttributedRemedy_includesTheSystemSettingsStep() {
        // Verify round 3 row 11: the banner had no System Settings step, so for a recorded
        // "Don't Allow" its only advice was a --setup that cannot re-prompt.
        let plain = ResponsibleProcessFormatter.hostAttributedRemedy(
            setupCommand: "'x' --setup", settingsPane: "Calendar / Reminders", alsoEnable: nil)
        XCTAssertTrue(plain[2].contains("Open System Settings → Privacy & Security → Calendar / Reminders"))
        XCTAssertTrue(plain[2].contains("Don't Allow"))
        let app = ResponsibleProcessFormatter.hostAttributedRemedy(
            setupCommand: "'x' --setup", settingsPane: "Calendar", alsoEnable: "enable Terminal")
        XCTAssertTrue(app[2].contains("enable Terminal to keep using its grant"))
    }

    func testAttribution_hostWithFullAccess_saysTheGrantIsKept_notThatTheReexecFailed() {
        // Verify round 3 row 3: under the status-aware rule a Claude Code host with full access
        // is the normal, intended state, and the failure causes did not apply.
        let host = ResponsibleProcessResult.resolved(ResponsibleProcess(
            pid: 9664, path: "/Users/u/.local/share/claude/versions/2.1.309", isSelf: false))
        let kept = ResponsibleProcessFormatter.attributionSection(selfPid: 500, result: host, hostGrantUsable: true)
        XCTAssertFalse(kept.contains("was not re-executed"), kept)
        XCTAssertTrue(kept.contains("keeps"), kept)
        let failed = ResponsibleProcessFormatter.attributionSection(selfPid: 500, result: host, hostGrantUsable: false)
        XCTAssertTrue(failed.contains("was not re-executed"), failed)
    }

    func testSetupTarget_host_warnsTheGrantGoesElsewhere() {
        let line = ResponsibleProcessFormatter.setupTargetLine(
            .resolved(ResponsibleProcess(pid: 3599, path: "/Applications/Terminal.app/Contents/MacOS/Terminal", isSelf: false)))
        XCTAssertTrue(line.contains("WARNING"))
        XCTAssertTrue(line.contains("Terminal"))
        XCTAssertTrue(line.contains("CHE_ICAL_MCP_NO_DISCLAIM"))
        XCTAssertTrue(line.contains("CHE_ICAL_MCP_DISCLAIMED"), "verify round 3 row 8")
    }

    func testSetupTarget_unavailable_rendersTheReason() {
        let line = ResponsibleProcessFormatter.setupTargetLine(.unavailable(reason: "responsibility SPI not found in this macOS"))
        XCTAssertTrue(line.contains("Authorization target: unknown (responsibility SPI not found in this macOS)"))
    }

    func testControlCharactersInThePath_areEscaped() {
        let s = ResponsibleProcessFormatter.attributionSection(
            selfPid: 500,
            result: .resolved(ResponsibleProcess(pid: 9, path: "/tmp/\u{1B}[2J.app/Contents/MacOS/x", isSelf: false)))
        XCTAssertFalse(s.unicodeScalars.contains { $0.value == 0x1B }, "raw ESC must never reach stdout")
    }
}
