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
        eventKitAccessGranted: Bool
    ) -> TCCDriftDetector {
        TCCDriftDetector(
            tcc: FakeTCCDatabaseSource(entries: []),
            processes: FakeProcessInventorySource(processes: []),
            runningBinaryPath: runningPath,
            diskBinaryMtime: nil,
            parentChain: chain,
            eventKitAccessGranted: eventKitAccessGranted
        )
    }

    func testSignal_whenVersionedClaudeHostAndCalendarUngranted() {
        let chain = FakeParentChainSource(hops: [
            .init(pid: 400, command: "/bin/zsh"),
            .init(pid: 300, command: versionedHostPath),
            .init(pid: 1, command: "/sbin/launchd"),
        ])
        let report = makeDetector(chain: chain, eventKitAccessGranted: false).detect()
        XCTAssertTrue(report.signals.contains(.versionedClaudeHostUngranted(hostPath: versionedHostPath)))
    }

    func testNoSignal_whenCalendarGranted() {
        // Granted users must see zero extra noise, even under a versioned host.
        let chain = FakeParentChainSource(hops: [
            .init(pid: 300, command: versionedHostPath)
        ])
        let report = makeDetector(chain: chain, eventKitAccessGranted: true).detect()
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
        let report = makeDetector(chain: chain, eventKitAccessGranted: false).detect()
        XCTAssertFalse(report.signals.contains { signal in
            if case .versionedClaudeHostUngranted = signal { return true }
            return false
        })
        XCTAssertFalse(report.skipReasons.contains { $0.contains("versioned-host") },
                       "a successful capture with no versioned host is a clean miss, not a skip")
    }

    func testSkipReason_whenChainCaptureFails() {
        let chain = FakeParentChainSource(failureReason: "ps timed out after 500ms")
        let report = makeDetector(chain: chain, eventKitAccessGranted: false).detect()
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

    // MARK: - verify in-scope fixes (DA-1 / DA-2 / Codex spy)

    func testDetector_gateCountsRemindersOnlyBreakage() {
        // DA-1: the issue's scope is EventKit (Calendar AND Reminders). The detector
        // gate takes a combined eventKitAccessGranted flag — false when EITHER service
        // is ungranted — so a Reminders-only breakage under a versioned host still
        // gets the rotation explanation instead of total silence.
        let chain = FakeParentChainSource(hops: [.init(pid: 300, command: versionedHostPath)])
        let report = makeDetector(chain: chain, eventKitAccessGranted: false).detect()
        XCTAssertTrue(report.signals.contains(.versionedClaudeHostUngranted(hostPath: versionedHostPath)))
    }

    func testDetector_grantedPath_neverSpawnsChainCapture() {
        // Codex cross-model suggestion: the "granted users pay zero subprocess cost"
        // promise is observable, not just structural — assert the seam is never called.
        let spy = SpyParentChainSource(hops: [.init(pid: 300, command: versionedHostPath)])
        let detector = TCCDriftDetector(
            tcc: FakeTCCDatabaseSource(entries: []),
            processes: FakeProcessInventorySource(processes: []),
            runningBinaryPath: runningPath,
            diskBinaryMtime: nil,
            parentChain: spy,
            eventKitAccessGranted: true
        )
        _ = detector.detect()
        XCTAssertEqual(spy.captureCallCount, 0)
    }

    func testBanner_suppressesSetupLineWhenVersionedHostSignalPresent() {
        // DA-2: `--setup` grants CheICalMCP-as-foreground-app's OWN attribution — the
        // wrong identity for the versioned-host case, where the HOST's grant is what
        // rotated away (#168/#170). When the #175 signal fires, the #163 --setup line
        // must yield to it instead of pointing users into a dead end.
        let report = DriftReport(
            signals: [.versionedClaudeHostUngranted(hostPath: versionedHostPath)],
            skipReasons: []
        )
        let banner = TCCDriftDetector.formatBanner(
            report: report, version: "1.14.2", runningBinaryPath: runningPath,
            pid: 123, bundleID: "com.checheng.CheICalMCP", calendarAccessGranted: false)
        XCTAssertFalse(banner.contains("--setup"),
                       "contradictory remediation: --setup targets the wrong attribution identity here")
    }

    func testBanner_keepsSetupLineWithoutVersionedHostSignal() {
        // Control for the suppression: the #163 line is unchanged when the #175 signal
        // is absent (plain ungranted case, e.g. Terminal host).
        let report = DriftReport(signals: [], skipReasons: [])
        let banner = TCCDriftDetector.formatBanner(
            report: report, version: "1.14.2", runningBinaryPath: runningPath,
            pid: 123, bundleID: "com.checheng.CheICalMCP", calendarAccessGranted: false)
        XCTAssertTrue(banner.contains("--setup"))
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
