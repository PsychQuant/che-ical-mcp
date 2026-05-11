import XCTest
@testable import CheICalMCP

/// Pure unit tests for `TCCDriftDetector`. Per the test-naming convention in CLAUDE.md
/// this file is `*Tests.swift` (pure unit, no handler wiring, no subprocess spawn).
///
/// The 9 scenarios cover the 2-signal × happy/skip matrix plus banner-format invariants.
final class TCCDriftDetectorTests: XCTestCase {

    // The path the running binary is "at" for these tests. Tests configure TCC entries
    // and processes relative to this.
    private let runningPath = "/Users/test/bin/CheICalMCP"
    private let bundleID = "com.checheng.CheICalMCP"

    // Disk binary mtime: "Monday May 11 22:36 2026" — slightly later than the stale
    // process fixtures so a process started before this date is considered stale.
    private let diskMtime = TCCDriftFixtures.lstartDate("Mon May 11 22:36:00 2026")

    // MARK: - Signal detection

    func testNoDriftWhenTCCEntryMatchesAndNoStaleProcesses() {
        let tcc = FakeTCCDatabaseSource(entries: [
            TCCDriftFixtures.entry(service: "kTCCServiceCalendar", client: runningPath),
            TCCDriftFixtures.entry(service: "kTCCServiceReminders", client: runningPath)
        ])
        let processes = FakeProcessInventorySource(processes: [])

        let detector = TCCDriftDetector(
            tcc: tcc,
            processes: processes,
            runningBinaryPath: runningPath,
            diskBinaryMtime: diskMtime
        )

        let report = detector.detect()

        XCTAssertTrue(report.signals.isEmpty)
        XCTAssertTrue(report.skipReasons.isEmpty)
    }

    func testTCCPathMismatchSignalEmittedPerService() {
        let mcpbPath = "/Users/test/Library/Application Support/Claude/.../CheICalMCP"
        let tcc = FakeTCCDatabaseSource(entries: [
            TCCDriftFixtures.entry(service: "kTCCServiceCalendar", client: mcpbPath),
            TCCDriftFixtures.entry(service: "kTCCServiceReminders", client: mcpbPath)
        ])
        let processes = FakeProcessInventorySource(processes: [])

        let detector = TCCDriftDetector(
            tcc: tcc,
            processes: processes,
            runningBinaryPath: runningPath,
            diskBinaryMtime: diskMtime
        )

        let report = detector.detect()

        // Two signals — one per service.
        XCTAssertEqual(report.signals.count, 2)
        let services = report.signals.compactMap { signal -> String? in
            if case .tccPathMismatch(let service, _, _) = signal { return service }
            return nil
        }
        XCTAssertEqual(Set(services), Set(["kTCCServiceCalendar", "kTCCServiceReminders"]))
    }

    func testNoMismatchSignalWhenRuntimePathAlsoHasEntry() {
        // TCC.db has both the mcpb path AND the runtime path: drift detector should
        // recognize the runtime path is granted and stay silent.
        let mcpbPath = "/Users/test/Library/Application Support/Claude/.../CheICalMCP"
        let tcc = FakeTCCDatabaseSource(entries: [
            TCCDriftFixtures.entry(service: "kTCCServiceCalendar", client: mcpbPath),
            TCCDriftFixtures.entry(service: "kTCCServiceCalendar", client: runningPath)
        ])
        let processes = FakeProcessInventorySource(processes: [])

        let detector = TCCDriftDetector(
            tcc: tcc,
            processes: processes,
            runningBinaryPath: runningPath,
            diskBinaryMtime: diskMtime
        )

        let report = detector.detect()

        XCTAssertTrue(report.signals.isEmpty, "runtime path also granted → no mismatch")
    }

    func testStaleProcessesDetectedWhenStartedBeforeDiskMtime() {
        let processes = FakeProcessInventorySource(processes: [
            TCCDriftFixtures.process(
                pid: 99001,
                startedAt: TCCDriftFixtures.lstartDate("Wed May 6 15:32:14 2026")
            ),
            TCCDriftFixtures.process(
                pid: 99002,
                startedAt: TCCDriftFixtures.lstartDate("Thu May 7 07:33:21 2026")
            )
        ])

        let detector = TCCDriftDetector(
            tcc: FakeTCCDatabaseSource(entries: [
                TCCDriftFixtures.entry(client: runningPath)
            ]),
            processes: processes,
            runningBinaryPath: runningPath,
            diskBinaryMtime: diskMtime
        )

        let report = detector.detect()

        XCTAssertEqual(report.signals.count, 1)
        if case .staleProcesses(let count, _, let samplePIDs) = report.signals.first {
            XCTAssertEqual(count, 2)
            XCTAssertEqual(Set(samplePIDs), Set([99001, 99002]))
        } else {
            XCTFail("expected .staleProcesses signal")
        }
    }

    func testProcessStartedAfterDiskMtimeIsNotStale() {
        let processes = FakeProcessInventorySource(processes: [
            TCCDriftFixtures.process(
                pid: 99003,
                startedAt: TCCDriftFixtures.lstartDate("Mon May 11 22:36:52 2026") // 52s after disk mtime
            )
        ])

        let detector = TCCDriftDetector(
            tcc: FakeTCCDatabaseSource(entries: [
                TCCDriftFixtures.entry(client: runningPath)
            ]),
            processes: processes,
            runningBinaryPath: runningPath,
            diskBinaryMtime: diskMtime
        )

        XCTAssertTrue(detector.detect().signals.isEmpty)
    }

    func testStalePIDListLimitedToConfiguredCount() {
        // 7 stale processes; limit is default 5 → samplePIDs should have 5 items, count
        // should report the full 7.
        let staleProcesses: [RunningProcess] = (90000..<90007).map { pid in
            TCCDriftFixtures.process(
                pid: Int32(pid),
                startedAt: TCCDriftFixtures.lstartDate("Wed May 6 15:32:14 2026")
            )
        }

        let detector = TCCDriftDetector(
            tcc: FakeTCCDatabaseSource(entries: [
                TCCDriftFixtures.entry(client: runningPath)
            ]),
            processes: FakeProcessInventorySource(processes: staleProcesses),
            runningBinaryPath: runningPath,
            diskBinaryMtime: diskMtime
        )

        let report = detector.detect()
        guard case .staleProcesses(let count, _, let samplePIDs) = report.signals.first else {
            return XCTFail("expected .staleProcesses signal")
        }

        XCTAssertEqual(count, 7)
        XCTAssertEqual(samplePIDs.count, 5)
    }

    func testBothSignalsTogether() {
        let mcpbPath = "/Users/test/Library/Application Support/Claude/.../CheICalMCP"
        let detector = TCCDriftDetector(
            tcc: FakeTCCDatabaseSource(entries: [
                TCCDriftFixtures.entry(service: "kTCCServiceCalendar", client: mcpbPath)
            ]),
            processes: FakeProcessInventorySource(processes: [
                TCCDriftFixtures.process(
                    pid: 99010,
                    startedAt: TCCDriftFixtures.lstartDate("Wed May 6 15:32:14 2026")
                )
            ]),
            runningBinaryPath: runningPath,
            diskBinaryMtime: diskMtime
        )

        XCTAssertEqual(detector.detect().signals.count, 2)
    }

    // MARK: - Skip reasons

    func testTCCFailureProducesSkipReason() {
        let detector = TCCDriftDetector(
            tcc: FakeTCCDatabaseSource(failureReason: "sqlite3 not at /usr/bin/sqlite3"),
            processes: FakeProcessInventorySource(processes: []),
            runningBinaryPath: runningPath,
            diskBinaryMtime: diskMtime
        )

        let report = detector.detect()

        XCTAssertTrue(report.signals.isEmpty)
        XCTAssertEqual(report.skipReasons.count, 1)
        XCTAssertTrue(
            report.skipReasons[0].contains("TCC check skipped"),
            "skip reason should be labeled TCC: \(report.skipReasons)"
        )
    }

    func testProcessFailureProducesSkipReason() {
        let detector = TCCDriftDetector(
            tcc: FakeTCCDatabaseSource(entries: [
                TCCDriftFixtures.entry(client: runningPath)
            ]),
            processes: FakeProcessInventorySource(failureReason: "ps exit 1: I/O error"),
            runningBinaryPath: runningPath,
            diskBinaryMtime: diskMtime
        )

        let report = detector.detect()

        XCTAssertTrue(report.signals.isEmpty)
        XCTAssertEqual(report.skipReasons.count, 1)
        XCTAssertTrue(
            report.skipReasons[0].contains("process check skipped"),
            "skip reason should be labeled process: \(report.skipReasons)"
        )
    }

    func testMissingDiskMtimeSkipsProcessCheck() {
        // Without disk mtime there's no cutoff for "stale", so we shouldn't emit a
        // stale-process signal regardless of process state.
        let detector = TCCDriftDetector(
            tcc: FakeTCCDatabaseSource(entries: [
                TCCDriftFixtures.entry(client: runningPath)
            ]),
            processes: FakeProcessInventorySource(processes: [
                TCCDriftFixtures.process(
                    pid: 99020,
                    startedAt: TCCDriftFixtures.lstartDate("Wed May 6 15:32:14 2026")
                )
            ]),
            runningBinaryPath: runningPath,
            diskBinaryMtime: nil
        )

        let report = detector.detect()

        XCTAssertTrue(report.signals.isEmpty)
        XCTAssertEqual(report.skipReasons.count, 1)
        XCTAssertTrue(report.skipReasons[0].contains("disk binary mtime unavailable"))
    }

    // MARK: - Banner format

    func testFormatBannerOKCase() {
        let banner = TCCDriftDetector.formatBanner(
            report: DriftReport(signals: [], skipReasons: []),
            version: "1.10.0",
            runningBinaryPath: runningPath,
            pid: 12345,
            bundleID: bundleID
        )

        XCTAssertTrue(banner.contains("che-ical-mcp 1.10.0"))
        XCTAssertTrue(banner.contains("TCC OK, no stale processes"))
        XCTAssertTrue(banner.contains("PID 12345"))
        XCTAssertTrue(banner.contains(runningPath))
        // OK case is at most 2 lines (banner header + binary path). One trailing newline.
        let nonEmpty = banner.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertLessThanOrEqual(nonEmpty.count, 2)
    }

    func testFormatBannerIncludesActionableCommands() {
        let report = DriftReport(
            signals: [
                .tccPathMismatch(
                    service: "kTCCServiceCalendar",
                    runningBinaryPath: runningPath,
                    recordedClient: "/other/path/CheICalMCP"
                ),
                .staleProcesses(
                    count: 3,
                    oldestStartedAt: TCCDriftFixtures.lstartDate("Wed May 6 15:32:14 2026"),
                    samplePIDs: [99100, 99101, 99102]
                )
            ],
            skipReasons: []
        )

        let banner = TCCDriftDetector.formatBanner(
            report: report,
            version: "1.10.0",
            runningBinaryPath: runningPath,
            pid: 12345,
            bundleID: bundleID
        )

        // Per-signal lines + their actionable hints.
        XCTAssertTrue(banner.contains("TCC.db Calendar entry path mismatch"))
        XCTAssertTrue(banner.contains("tccutil reset Calendar com.checheng.CheICalMCP"))
        XCTAssertTrue(banner.contains("3 stale CheICalMCP processes running"))
        XCTAssertTrue(banner.contains("pkill -f"))
        // Drift status surfaces signal count.
        XCTAssertTrue(banner.contains("drift detected (2 signals)"))
    }

    func testFormatBannerSurfacesSkipReasons() {
        let banner = TCCDriftDetector.formatBanner(
            report: DriftReport(signals: [], skipReasons: ["TCC check skipped: db locked"]),
            version: "1.10.0",
            runningBinaryPath: runningPath,
            pid: 12345,
            bundleID: bundleID
        )

        XCTAssertTrue(banner.contains("TCC check skipped: db locked"))
    }
}
