import XCTest
@testable import CheICalMCP

/// Coverage for the #175 versioned-host signal: when the MCP server starts under a
/// Claude Code **versioned** host binary (`~/.local/share/claude/versions/<v>` — the
/// path rotates on every update, #170) AND EventKit isn't granted in this context,
/// the banner must say so proactively instead of letting the user discover it as a
/// silent `access denied` on their first tool call.
final class TCCDriftVersionedHostTests: XCTestCase {

    private let runningPath = "/Users/test/bin/CheICalMCP"
    private let versionedHostPath = "/Users/test/.local/share/claude/versions/2.1.206"

    private func makeDetector(
        chain: FakeParentChainSource,
        calendarAccessGranted: Bool
    ) -> TCCDriftDetector {
        TCCDriftDetector(
            tcc: FakeTCCDatabaseSource(entries: []),
            processes: FakeProcessInventorySource(processes: []),
            runningBinaryPath: runningPath,
            diskBinaryMtime: nil,
            parentChain: chain,
            calendarAccessGranted: calendarAccessGranted
        )
    }

    func testSignal_whenVersionedClaudeHostAndCalendarUngranted() {
        let chain = FakeParentChainSource(hops: [
            .init(pid: 400, command: "/bin/zsh"),
            .init(pid: 300, command: versionedHostPath),
            .init(pid: 1, command: "/sbin/launchd"),
        ])
        let report = makeDetector(chain: chain, calendarAccessGranted: false).detect()
        XCTAssertTrue(report.signals.contains(.versionedClaudeHostUngranted(hostPath: versionedHostPath)))
    }

    func testNoSignal_whenCalendarGranted() {
        // Granted users must see zero extra noise, even under a versioned host.
        let chain = FakeParentChainSource(hops: [
            .init(pid: 300, command: versionedHostPath)
        ])
        let report = makeDetector(chain: chain, calendarAccessGranted: true).detect()
        XCTAssertFalse(report.signals.contains { signal in
            if case .versionedClaudeHostUngranted = signal { return true }
            return false
        })
    }

    func testNoSignal_whenChainLacksVersionedClaudePath() {
        // Plain Terminal chain, ungranted: the existing #163 --setup banner line covers
        // this; the #175 signal is specifically about the rotating-host explanation.
        let chain = FakeParentChainSource(hops: [
            .init(pid: 400, command: "/bin/zsh"),
            .init(pid: 1, command: "/sbin/launchd"),
        ])
        let report = makeDetector(chain: chain, calendarAccessGranted: false).detect()
        XCTAssertFalse(report.signals.contains { signal in
            if case .versionedClaudeHostUngranted = signal { return true }
            return false
        })
        XCTAssertFalse(report.skipReasons.contains { $0.contains("versioned-host") },
                       "a successful capture with no versioned host is a clean miss, not a skip")
    }

    func testSkipReason_whenChainCaptureFails() {
        let chain = FakeParentChainSource(failureReason: "ps timed out after 500ms")
        let report = makeDetector(chain: chain, calendarAccessGranted: false).detect()
        XCTAssertFalse(report.signals.contains { signal in
            if case .versionedClaudeHostUngranted = signal { return true }
            return false
        })
        XCTAssertTrue(report.skipReasons.contains { $0.contains("versioned-host check skipped") },
                      "capture failure must degrade visibly, not silently (#122 advisory contract)")
    }

    // MARK: - Banner rendering

    func testBanner_rendersHostPathRotationExplanationAndAction() {
        let report = DriftReport(
            signals: [.versionedClaudeHostUngranted(hostPath: versionedHostPath)],
            skipReasons: []
        )
        let banner = TCCDriftDetector.formatBanner(
            report: report, version: "1.14.2", runningBinaryPath: runningPath,
            pid: 123, bundleID: "com.checheng.CheICalMCP", calendarAccessGranted: false)
        XCTAssertTrue(banner.contains(versionedHostPath))
        XCTAssertTrue(banner.contains("#170"), "the rotation phenomenon has a tracking issue — cite it")
        XCTAssertTrue(banner.contains("System Settings"), "the fix path must be actionable")
        XCTAssertTrue(banner.contains("rotates"), "explain WHY the grant broke (update rotated the path)")
    }

    func testBanner_escapesHostileHostPath() {
        let report = DriftReport(
            signals: [.versionedClaudeHostUngranted(hostPath: "/tmp/\u{1B}[2J/versions/2.1.206")],
            skipReasons: []
        )
        let banner = TCCDriftDetector.formatBanner(
            report: report, version: "1.14.2", runningBinaryPath: runningPath,
            pid: 123, bundleID: "com.checheng.CheICalMCP", calendarAccessGranted: false)
        XCTAssertFalse(banner.unicodeScalars.contains { $0.value == 0x1B },
                       "host path comes from ps comm — same CWE-117 stderr discipline as every banner field")
    }
}
