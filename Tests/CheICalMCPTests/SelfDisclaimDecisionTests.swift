import XCTest
@testable import CheICalMCP

/// Coverage for `SelfDisclaim.decide` (#343) — whether CheICalMCP re-execs itself as its
/// own responsible process before any dispatch. The skip reasons are a closed set of five;
/// each has a test, and every TCC-touching mode is pinned to `.reexec` under a host.
final class SelfDisclaimDecisionTests: XCTestCase {

    private let binary = "/Users/u/bin/CheICalMCP"
    private let hostResponsible = ResponsibleProcessResult.resolved(ResponsibleProcess(
        pid: 3599,
        path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron",
        isSelf: false))

    private func decide(
        _ extraArgs: [String] = [],
        env: [String: String] = [:],
        responsible: ResponsibleProcessResult? = nil
    ) -> SelfDisclaimDecision {
        SelfDisclaim.decide(
            arguments: [binary] + extraArgs,
            environment: env,
            responsible: responsible ?? hostResponsible)
    }

    // MARK: - The five skip reasons

    func testAlreadyDisclaimedSentinel_skipsSoItCannotLoop() {
        XCTAssertEqual(decide(env: ["CHE_ICAL_MCP_DISCLAIMED": "1"]), .skip(.alreadyDisclaimed))
    }

    func testOptOut_skips() {
        XCTAssertEqual(decide(env: ["CHE_ICAL_MCP_NO_DISCLAIM": "1"]), .skip(.optedOut))
    }

    func testOptOutWithEmptyValue_isNotAnOptOut() {
        // Same convention as CHE_ICAL_MCP_NO_BANNER: an exported-but-empty variable is unset.
        XCTAssertEqual(decide(env: ["CHE_ICAL_MCP_NO_DISCLAIM": ""]), .reexec)
    }

    func testAlreadySelfResponsible_skips() {
        // Claude Desktop's .mcpb server runs under `disclaimer` and is already its own client.
        let selfResponsible = ResponsibleProcessResult.resolved(
            ResponsibleProcess(pid: 42, path: binary, isSelf: true))
        XCTAssertEqual(decide(responsible: selfResponsible), .skip(.alreadySelfResponsible))
    }

    func testFlagsThatNeverTouchTCC_skip() {
        for flag in ["--version", "-v", "--help", "-h", "--self-update"] {
            XCTAssertEqual(decide([flag]), .skip(.noTCCAccessNeeded), "flag \(flag)")
        }
    }

    func testResponsibilityUnavailable_skipsWithTheReason() {
        XCTAssertEqual(
            decide(responsible: .unavailable(reason: "responsibility SPI not found in this macOS")),
            .skip(.responsibilityUnavailable("responsibility SPI not found in this macOS")))
    }

    // MARK: - Every TCC-touching mode re-execs under a host

    func testServerMode_reexecs() {
        XCTAssertEqual(decide(), .reexec)
    }

    func testPrintTCCPath_reexecs() {
        XCTAssertEqual(decide(["--print-tcc-path"]), .reexec)
    }

    func testSetup_reexecsSoTheGrantLandsOnThisBinary() {
        XCTAssertEqual(decide(["--setup"]), .reexec)
    }

    func testCLI_reexecs() {
        XCTAssertEqual(decide(["--cli", "list_calendars"]), .reexec)
    }

    func testClaudeCodeHost_reexecs() {
        let claudeCode = ResponsibleProcessResult.resolved(ResponsibleProcess(
            pid: 9664, path: "/Users/u/.local/share/claude/versions/2.1.309", isSelf: false))
        XCTAssertEqual(decide(responsible: claudeCode), .reexec)
    }
}
