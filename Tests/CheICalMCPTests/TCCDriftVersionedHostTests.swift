import XCTest
@testable import CheICalMCP

/// Coverage for the host-attribution signal (#175, reworked in #343). When EventKit is not
/// granted and macOS charges the access to a host instead of CheICalMCP, the banner must
/// name that host and what to do about it, instead of letting the user discover it as a
/// silent `access denied` on their first tool call.
///
/// #343: the host is the *responsible process* the kernel reports, not a `versions/` path
/// found on the parent chain. A daemon-launched worker (responsible = Claude Code) and a
/// spare-claimed session (responsible = the app that launched the daemon) have the same
/// chain shape, so the chain-based check named the wrong client.
final class TCCDriftVersionedHostTests: XCTestCase {

    private let runningPath = "/Users/test/bin/CheICalMCP"
    private let versionedHostPath = "/Users/test/.local/share/claude/versions/2.1.206"
    private let vsCodePath = "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"

    private func resolved(_ path: String, isSelf: Bool = false) -> ResponsibleProcessResult {
        .resolved(ResponsibleProcess(pid: 300, path: path, isSelf: isSelf))
    }

    private func makeDetector(
        responsible: ResponsibleProcessResult,
        eventKitAccessGranted: Bool
    ) -> TCCDriftDetector {
        TCCDriftDetector(
            tcc: FakeTCCDatabaseSource(entries: []),
            processes: FakeProcessInventorySource(processes: []),
            runningBinaryPath: runningPath,
            diskBinaryMtime: nil,
            responsibleProcess: FakeResponsibleProcessSource(result: responsible),
            eventKitAccessGranted: eventKitAccessGranted
        )
    }

    private func hasHostSignal(_ report: DriftReport) -> Bool {
        report.signals.contains { signal in
            if case .hostAttributedUngranted = signal { return true }
            return false
        }
    }

    // MARK: - Detection

    func testSignal_whenClaudeCodeIsResponsibleAndUngranted() {
        let report = makeDetector(responsible: resolved(versionedHostPath), eventKitAccessGranted: false).detect()
        XCTAssertTrue(report.signals.contains(
            .hostAttributedUngranted(host: .claudeCode(version: "2.1.206"), hostPath: versionedHostPath)))
    }

    func testSignal_whenAnAppIsResponsibleAndUngranted() {
        // The opt-out case: CHE_ICAL_MCP_NO_DISCLAIM under a daemon launched from VS Code.
        let report = makeDetector(responsible: resolved(vsCodePath), eventKitAccessGranted: false).detect()
        XCTAssertTrue(report.signals.contains(
            .hostAttributedUngranted(host: .appBundle(name: "Visual Studio Code"), hostPath: vsCodePath)))
    }

    func testNoSignal_whenSelfResponsible_evenUnderAClaudeCodeParent() {
        // #343 regression: after the re-exec CheICalMCP is its own responsible process
        // while its parent is still Claude Code. The old check found `versions/` on the
        // chain and blamed the host; the right advice here is the existing --setup line.
        let report = makeDetector(
            responsible: resolved(runningPath, isSelf: true), eventKitAccessGranted: false).detect()
        XCTAssertFalse(hasHostSignal(report))
        XCTAssertFalse(report.skipReasons.contains { $0.contains("TCC attribution") },
                       "a resolved self attribution is a clean miss, not a skip")
    }

    func testNoSignal_whenGranted() {
        let report = makeDetector(responsible: resolved(versionedHostPath), eventKitAccessGranted: true).detect()
        XCTAssertFalse(hasHostSignal(report))
    }

    func testSkipReason_whenResponsibilityUnavailable() {
        let report = makeDetector(
            responsible: .unavailable(reason: "responsibility SPI not found in this macOS"),
            eventKitAccessGranted: false).detect()
        XCTAssertFalse(hasHostSignal(report))
        XCTAssertTrue(report.skipReasons.contains { $0.contains("TCC attribution check skipped") },
                      "lookup failure must degrade visibly, not silently (#122 advisory contract)")
    }

    func testDetector_grantedPath_neverQueriesTheKernel() {
        // Granted users pay nothing for this check — observable, not just structural.
        let spy = SpyResponsibleProcessSource(result: resolved(versionedHostPath))
        let detector = TCCDriftDetector(
            tcc: FakeTCCDatabaseSource(entries: []),
            processes: FakeProcessInventorySource(processes: []),
            runningBinaryPath: runningPath,
            diskBinaryMtime: nil,
            responsibleProcess: spy,
            eventKitAccessGranted: true
        )
        _ = detector.detect()
        XCTAssertEqual(spy.callCount, 0)
    }

    // MARK: - Banner rendering

    func testBanner_claudeCodeHost_explainsItCannotBePrompted() {
        let report = DriftReport(
            signals: [.hostAttributedUngranted(host: .claudeCode(version: "2.1.206"), hostPath: versionedHostPath)],
            skipReasons: [])
        let banner = TCCDriftDetector.formatBanner(
            report: report, version: "1.21.0", runningBinaryPath: runningPath,
            pid: 123, bundleID: "com.checheng.CheICalMCP", calendarAccessGranted: false)
        XCTAssertTrue(banner.contains(versionedHostPath))
        XCTAssertTrue(banner.contains("no Calendar or Reminders purpose string"))
        XCTAssertTrue(banner.contains("CHE_ICAL_MCP_NO_DISCLAIM"))
        XCTAssertTrue(banner.contains("#343"))
    }

    func testBanner_appHost_namesTheAppsGrant() {
        let report = DriftReport(
            signals: [.hostAttributedUngranted(host: .appBundle(name: "Visual Studio Code"), hostPath: vsCodePath)],
            skipReasons: [])
        let banner = TCCDriftDetector.formatBanner(
            report: report, version: "1.21.0", runningBinaryPath: runningPath,
            pid: 123, bundleID: "com.checheng.CheICalMCP", calendarAccessGranted: false)
        XCTAssertTrue(banner.contains("Visual Studio Code's grant"))
    }

    func testBanner_suppressesSetupLineWhenAHostIsResponsible() {
        // `--setup` grants CheICalMCP's own attribution, which a host-attributed process
        // does not use — printing it alongside the host advice would contradict it.
        let report = DriftReport(
            signals: [.hostAttributedUngranted(host: .claudeCode(version: "2.1.206"), hostPath: versionedHostPath)],
            skipReasons: [])
        let banner = TCCDriftDetector.formatBanner(
            report: report, version: "1.21.0", runningBinaryPath: runningPath,
            pid: 123, bundleID: "com.checheng.CheICalMCP", calendarAccessGranted: false)
        XCTAssertFalse(banner.contains("--setup"))
    }

    func testBanner_keepsSetupLineWithoutAHostSignal() {
        // Self-attributed and ungranted (the #343 default after an upgrade): --setup is the fix.
        let report = DriftReport(signals: [], skipReasons: [])
        let banner = TCCDriftDetector.formatBanner(
            report: report, version: "1.21.0", runningBinaryPath: runningPath,
            pid: 123, bundleID: "com.checheng.CheICalMCP", calendarAccessGranted: false)
        XCTAssertTrue(banner.contains("--setup"))
    }

    func testBanner_escapesHostileHostPath() {
        let report = DriftReport(
            signals: [.hostAttributedUngranted(
                host: .otherExecutable(path: "/tmp/\u{1B}[2J/x"), hostPath: "/tmp/\u{1B}[2J/x")],
            skipReasons: [])
        let banner = TCCDriftDetector.formatBanner(
            report: report, version: "1.21.0", runningBinaryPath: runningPath,
            pid: 123, bundleID: "com.checheng.CheICalMCP", calendarAccessGranted: false)
        XCTAssertFalse(banner.unicodeScalars.contains { $0.value == 0x1B },
                       "the host path names a file anyone can create — same CWE-117 stderr discipline")
    }
}
