import XCTest
@testable import CheICalMCP

/// Coverage for `SelfDisclaim.decide` (#343) — whether CheICalMCP re-execs itself as its
/// own responsible process before any dispatch. The skip reasons are a closed set of seven;
/// each has a test. The rule is deliberately narrow: re-exec only where the responsible
/// process is Claude Code (which can never be prompted), plus `--setup` (a deliberate,
/// foreground request for CheICalMCP's own grant) and an explicit `CHE_ICAL_MCP_FORCE_DISCLAIM`.
/// Every other host keeps its own grant, which may be the only one that works (verify of
/// PR #347: under VS Code the host was `fullAccess` and CheICalMCP's own grant was empty).
final class SelfDisclaimDecisionTests: XCTestCase {

    private let binary = "/Users/u/bin/CheICalMCP"
    private let vsCode = ResponsibleProcessResult.resolved(ResponsibleProcess(
        pid: 3599,
        path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
        isSelf: false))
    private let claudeCode = ResponsibleProcessResult.resolved(ResponsibleProcess(
        pid: 9664, path: "/Users/u/.local/share/claude/versions/2.1.309", isSelf: false))
    private let claudeCodeApp = ResponsibleProcessResult.resolved(ResponsibleProcess(
        pid: 9665, path: "/Users/u/.local/share/claude/ClaudeCode.app/Contents/MacOS/claude", isSelf: false))
    private let bareExecutable = ResponsibleProcessResult.resolved(ResponsibleProcess(
        pid: 1, path: "/sbin/launchd", isSelf: false))
    private let noPath = ResponsibleProcessResult.resolved(ResponsibleProcess(
        pid: 77, path: nil, isSelf: false))
    private let selfResponsible = ResponsibleProcessResult.resolved(ResponsibleProcess(
        pid: 42, path: "/Users/u/bin/CheICalMCP", isSelf: true))

    private func decide(
        _ extraArgs: [String] = [],
        env: [String: String] = [:],
        responsible: ResponsibleProcessResult? = nil
    ) -> SelfDisclaimDecision {
        SelfDisclaim.decide(
            arguments: [binary] + extraArgs,
            environment: env,
            responsible: responsible ?? vsCode)
    }

    // MARK: - The seven skip reasons

    func testAlreadyDisclaimedSentinel_skipsSoItCannotLoop() {
        XCTAssertEqual(decide(env: ["CHE_ICAL_MCP_DISCLAIMED": "1"]), .skip(.alreadyDisclaimed))
        // Self-responsible after the re-exec: the normal, healthy second image.
        XCTAssertEqual(
            decide(env: ["CHE_ICAL_MCP_DISCLAIMED": "1"], responsible: selfResponsible),
            .skip(.alreadyDisclaimed))
    }

    func testSentinelOnAClaudeCodeHost_isReportedAsIneffectiveNotSilentlyTrusted() {
        // The sentinel is an unauthenticated environment variable. If it is set while Claude
        // Code is still the responsible process, the re-exec either never took effect or the
        // variable is stale (inherited from a shell). It must still not loop, but it must
        // be a distinct, reportable outcome instead of a silent skip.
        XCTAssertEqual(
            decide(env: ["CHE_ICAL_MCP_DISCLAIMED": "1"], responsible: claudeCode),
            .skip(.disclaimIneffective))
        XCTAssertEqual(
            decide(env: ["CHE_ICAL_MCP_DISCLAIMED": "1"], responsible: claudeCodeApp),
            .skip(.disclaimIneffective))
    }

    func testOptOut_skips() {
        XCTAssertEqual(decide(env: ["CHE_ICAL_MCP_NO_DISCLAIM": "1"]), .skip(.optedOut))
        XCTAssertEqual(decide(env: ["CHE_ICAL_MCP_NO_DISCLAIM": "1"], responsible: claudeCode), .skip(.optedOut))
    }

    func testOptOutWinsOverForce() {
        XCTAssertEqual(
            decide(env: ["CHE_ICAL_MCP_NO_DISCLAIM": "1", "CHE_ICAL_MCP_FORCE_DISCLAIM": "1"]),
            .skip(.optedOut))
    }

    func testOptOutWithEmptyValue_isNotAnOptOut() {
        // Same convention as CHE_ICAL_MCP_NO_BANNER: an exported-but-empty variable is unset.
        XCTAssertEqual(decide(env: ["CHE_ICAL_MCP_NO_DISCLAIM": ""], responsible: claudeCode), .reexec)
    }

    func testAlreadySelfResponsible_skips() {
        // Claude Desktop's .mcpb server runs under `disclaimer` and is already its own client.
        XCTAssertEqual(decide(responsible: selfResponsible), .skip(.alreadySelfResponsible))
        XCTAssertEqual(
            decide(["--setup"], responsible: selfResponsible), .skip(.alreadySelfResponsible))
    }

    func testFlagsThatNeverTouchTCC_skip() {
        for flag in ["--version", "-v", "--help", "-h", "--self-update"] {
            XCTAssertEqual(decide([flag], responsible: claudeCode), .skip(.noTCCAccessNeeded), "flag \(flag)")
        }
    }

    func testResponsibilityUnavailable_skipsWithTheReason() {
        XCTAssertEqual(
            decide(responsible: .unavailable(reason: "responsibility SPI not found in this macOS")),
            .skip(.responsibilityUnavailable("responsibility SPI not found in this macOS")))
    }

    func testHostWithItsOwnGrant_keepsItInEveryModeButSetup() {
        // The case the verify found: swapping VS Code's working grant for CheICalMCP's empty
        // one breaks a setup that works today. Terminal, VS Code, launchd and a path-less
        // process are all left alone.
        for host in [vsCode, bareExecutable, noPath] {
            XCTAssertEqual(decide(responsible: host), .skip(.hostGrantIsUsable))
            XCTAssertEqual(decide(["--print-tcc-path"], responsible: host), .skip(.hostGrantIsUsable))
            XCTAssertEqual(decide(["--cli", "list_calendars"], responsible: host), .skip(.hostGrantIsUsable))
        }
    }

    // MARK: - Where the re-exec does happen

    func testClaudeCodeHost_reexecsInEveryTCCTouchingMode() {
        for host in [claudeCode, claudeCodeApp] {
            XCTAssertEqual(decide(responsible: host), .reexec)
            XCTAssertEqual(decide(["--print-tcc-path"], responsible: host), .reexec)
            XCTAssertEqual(decide(["--setup"], responsible: host), .reexec)
            XCTAssertEqual(decide(["--cli", "list_calendars"], responsible: host), .reexec)
        }
    }

    func testSetup_reexecsUnderAnyHostSoTheGrantLandsOnThisBinary() {
        // `--setup` is a deliberate foreground request for CheICalMCP's own grant.
        for host in [vsCode, bareExecutable, noPath, claudeCode] {
            XCTAssertEqual(decide(["--setup"], responsible: host), .reexec)
        }
    }

    func testForceDisclaim_reexecsUnderAnyOtherHost() {
        for host in [vsCode, bareExecutable, noPath] {
            XCTAssertEqual(decide(env: ["CHE_ICAL_MCP_FORCE_DISCLAIM": "1"], responsible: host), .reexec)
        }
        // An exported-but-empty variable is unset, like the others.
        XCTAssertEqual(
            decide(env: ["CHE_ICAL_MCP_FORCE_DISCLAIM": ""], responsible: vsCode), .skip(.hostGrantIsUsable))
    }

    func testForceDisclaim_stillNeverLoopsAndStillSkipsFlagsThatNeedNoTCC() {
        XCTAssertEqual(
            decide(env: ["CHE_ICAL_MCP_FORCE_DISCLAIM": "1", "CHE_ICAL_MCP_DISCLAIMED": "1"]),
            .skip(.alreadyDisclaimed))
        XCTAssertEqual(
            decide(["--version"], env: ["CHE_ICAL_MCP_FORCE_DISCLAIM": "1"]), .skip(.noTCCAccessNeeded))
    }
}
