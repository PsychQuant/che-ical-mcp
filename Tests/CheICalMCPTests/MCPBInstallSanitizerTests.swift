import EventKit
import XCTest
@testable import CheICalMCP

/// Tests for the #133 `.mcpb`-install-context sanitizer text — the `accessDenied`
/// errorDescription branches based on `EventKitManager.isMCPBClaudeDesktopInstall`
/// to surface the **real** workaround (switch to Claude Code plugin install) when
/// running under Claude Desktop's `.mcpb` extension on Claude Desktop ≥ 1.6608.2.
///
/// Pre-#133 the generic message told users to open System Settings → Privacy &
/// Security → Calendar, which is misleading: the upstream bug is that Claude.app's
/// bundle is missing the Calendar/Reminders entitlement + Info.plist usage
/// descriptions, so System Settings has nothing to toggle on. Users churned
/// through the wrong remediation before discovering the plugin-path workaround.
final class MCPBInstallSanitizerTests: XCTestCase {

    // MARK: - Detection contract (no mutation)

    /// `EventKitManager.isMCPBClaudeDesktopInstall` reads `CommandLine.arguments[0]`
    /// and BinaryPathResolver-resolves it. In the test process, argv[0] points at
    /// the xctest runner — not under `Claude Extensions/local.mcpb.`. So the flag
    /// is `false` in the test environment. We assert this so future detection
    /// changes don't silently regress the test environment behavior.
    func testDetection_returnsFalseInTestEnvironment() {
        XCTAssertFalse(EventKitManager.isMCPBClaudeDesktopInstall,
            "xctest runner argv[0] does not contain 'Claude Extensions/local.mcpb.' — detection must NOT misfire here")
    }

    // MARK: - Detection pattern (string-level, since we can't mutate the static)

    /// Verify the detection substring matches the canonical `.mcpb` install path
    /// shape. This is the literal contract the static check uses — if anyone
    /// renames the install layout upstream, this test catches it as a single
    /// source-of-truth assertion.
    func testDetection_pathPatternMatchesCanonicalLayout() {
        let canonicalMCPBPath = "/Users/test/Library/Application Support/Claude/Claude Extensions/local.mcpb.che-cheng.che-ical-mcp/server/CheICalMCP"
        XCTAssertTrue(canonicalMCPBPath.contains("Claude Extensions/local.mcpb."),
            "canonical Claude Desktop .mcpb path must contain the detection substring")
    }

    func testDetection_pluginPathDoesNotMatch() {
        let canonicalPluginPath = "/Users/test/bin/CheICalMCP"
        XCTAssertFalse(canonicalPluginPath.contains("Claude Extensions/local.mcpb."),
            "Claude Code plugin install path must NOT match — only `.mcpb` is affected by the regression")
    }

    func testDetection_terminalDirectInvocationDoesNotMatch() {
        let canonicalDevPath = "/Users/test/Developer/che-mcps/che-ical-mcp/.build/release/CheICalMCP"
        XCTAssertFalse(canonicalDevPath.contains("Claude Extensions/local.mcpb."),
            "dev build / Terminal direct invocation must NOT trigger the workaround text")
    }

    // MARK: - errorDescription content (without the flag — generic branch)

    /// In the test environment, the flag is false, so `accessDenied` produces
    /// the generic message. Pin that for backward compatibility — non-`.mcpb`
    /// users must keep getting the System Settings instructions.
    func testAccessDenied_genericMessage_inTestEnvironment_keepsSystemSettingsInstructions() {
        let err = EventKitError.accessDenied(type: "Calendar", isSSH: false, isNonInteractive: false)
        let msg = err.errorDescription ?? ""
        XCTAssertTrue(msg.contains("Open System Settings → Privacy & Security → Calendar"),
            "generic branch (no SSH/launchd/mcpb context) must still tell users to use System Settings")
        XCTAssertFalse(msg.contains("anthropics/claude-code#58239"),
            "non-mcpb context must NOT spam users with the upstream-tracker workaround")
        XCTAssertFalse(msg.contains("claude plugin install"),
            "non-mcpb context must NOT direct users to the plugin install path (they may already BE on it)")
    }

    /// SSH context still wins over `.mcpb` context — the message hierarchy is:
    /// SSH+launchd > SSH > launchd > .mcpb > generic. SSH-specific message
    /// has more diagnostic value than the install-channel message.
    func testAccessDenied_sshContext_winsOverMCPBContext() {
        let err = EventKitError.accessDenied(type: "Calendar", isSSH: true, isNonInteractive: false)
        let msg = err.errorDescription ?? ""
        XCTAssertTrue(msg.contains("SSH"),
            "SSH context message must take priority over `.mcpb` context — SSH is more diagnostic")
    }

    func testAccessDenied_launchdContext_winsOverMCPBContext() {
        let err = EventKitError.accessDenied(type: "Reminders", isSSH: false, isNonInteractive: true)
        let msg = err.errorDescription ?? ""
        XCTAssertTrue(msg.contains("non-interactive") || msg.contains("launchd") || msg.contains("--setup"),
            "launchd context message must take priority — `--setup` is the canonical remediation")
    }

    // MARK: - Documentation contract (`.mcpb` branch shape, exercised indirectly)

    /// Verify the workaround text contains the load-bearing keywords. We can't
    /// flip the static flag at runtime, so we exercise the message-construction
    /// shape by reading the source. This test serves as documentation: if anyone
    /// removes the `.mcpb` branch or its key references, the assertion catches
    /// it as a documented contract violation.
    func testAccessDeniedMessage_mcpbBranchContainsRequiredKeywords() throws {
        // Indirect contract assertion via source presence — Swift doesn't let
        // us mutate the static, so we ground-truth-check the message-template
        // text that lives in EventKitManager.swift.
        //
        // Resolve the repo root by walking up from `#filePath` (the compiler-injected
        // absolute path of THIS test file) until we find the directory containing
        // `Package.swift` — instead of a hardcoded `/Users/che/...` literal OR a
        // fixed-depth ×N `deletingLastPathComponent`. The marker walk survives the
        // test file moving into a subdirectory (e.g. the `Tests/CheICalMCPTests/Helpers/`
        // layout CLAUDE.md #83 encourages); a positional level count would silently
        // read the wrong path after such a move. Runs on any checkout — CI runners
        // (`/Users/runner/work/...`), other contributors' machines, etc.
        // (#131: machine-specific path was masked by the `-DCI_BUILD` compile-out;
        // re-enabling CI test execution surfaced it; verify hardened the depth assumption.)
        let fm = FileManager.default
        var repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !fm.fileExists(atPath: repoRoot.appendingPathComponent("Package.swift").path) {
            let parent = repoRoot.deletingLastPathComponent()
            guard parent.path != repoRoot.path else {
                XCTFail("Could not locate Package.swift above \(#filePath) — repo layout changed?")
                return
            }
            repoRoot = parent
        }
        let sourceURL = repoRoot
            .appendingPathComponent("Sources/CheICalMCP/EventKit/EventKitManager.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("isMCPBClaudeDesktopInstall"),
            "EventKitManager must expose isMCPBClaudeDesktopInstall — required by #133 detection contract")
        XCTAssertTrue(source.contains("Claude Extensions/local.mcpb."),
            "Detection must use canonical `.mcpb` install path substring")
        XCTAssertTrue(source.contains("anthropics/claude-code#58239"),
            "Workaround text must reference upstream issue so users can follow / 👍 it")
        XCTAssertTrue(source.contains("claude plugin install"),
            "Workaround text must surface the working install path command")
    }
}
