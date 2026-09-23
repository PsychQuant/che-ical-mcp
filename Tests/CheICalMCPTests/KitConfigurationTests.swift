import CheMCPKit
import XCTest

@testable import CheICalMCP

/// #223 — the values this server hands to che-mcp-kit-swift must reproduce what it hard-coded
/// before adopting the package (literals copied from `SelfUpdate.swift` / `CLIRunner.swift` at
/// v1.18.0), plus the Developer ID pin this issue adds.
final class KitConfigurationTests: XCTestCase {

    func testSelfUpdateURLsAndUserAgentMatchTheHardCodedValues() {
        let config = KitConfiguration.selfUpdate(currentVersion: "1.18.0")
        XCTAssertEqual(config.latestReleaseURL.absoluteString,
                       "https://api.github.com/repos/PsychQuant/che-ical-mcp/releases/latest")
        XCTAssertEqual(config.assetDownloadURL(tag: "v1.19.0", assetName: config.assetName + ".sha256").absoluteString,
                       "https://github.com/PsychQuant/che-ical-mcp/releases/download/v1.19.0/CheICalMCP.sha256")
        XCTAssertEqual(config.userAgent, "CheICalMCP/1.18.0 (self-update)")
        XCTAssertEqual(config.displayName, "CheICalMCP")
    }

    func testSelfUpdateComparesAgainstTheRunningVersion() {
        XCTAssertEqual(KitConfiguration.selfUpdate().currentVersion, AppVersion.current)
    }

    /// #223: a download must be Developer ID signed by this team and notarized before install.
    func testSelfUpdatePinsTheReleaseSigningTeam() throws {
        let verifier = try XCTUnwrap(KitConfiguration.selfUpdate().verifier as? SystemSignatureVerifier)
        XCTAssertEqual(verifier.expectedTeamID, "6W377FS7BS")
        XCTAssertTrue(verifier.designatedRequirement.hasPrefix("anchor apple generic"))
        XCTAssertTrue(verifier.designatedRequirement.hasSuffix(#"certificate leaf[subject.OU] = "6W377FS7BS""#))
    }

    func testUserVisibleMessagesThatNameTheBinaryAreUnchanged() {
        XCTAssertEqual(
            SelfUpdate.SelfUpdateError.binaryPathUnresolvable(binaryName: KitConfiguration.selfUpdate().assetName).localizedDescription,
            "Could not resolve current binary path. Run as `~/bin/CheICalMCP --self-update` so the binary path is unambiguous.")
        XCTAssertEqual(
            CLIRunner.CLIError.missingToolName(usageName: KitConfiguration.usageName).localizedDescription,
            "Missing tool name. Usage: CheICalMCP --cli <tool_name> [--key value ...]")
    }
}
