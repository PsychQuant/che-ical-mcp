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

    // MARK: - Verify-round-2 regression tests (B1/B2/B3)

    /// B2 fix: Calendar grants the mcpb path but Reminders grants the runtime path.
    /// Pre-fix code would suppress Calendar mismatch because *any* service matched the
    /// runtime path (global `runtimeHasMatch`). Post-fix the check is per-service, so
    /// Calendar mismatch must still surface.
    func testCalendarMismatchEmittedEvenWhenRemindersMatches() {
        let mcpbPath = "/Users/test/Library/Application Support/Claude/.../CheICalMCP"
        let tcc = FakeTCCDatabaseSource(entries: [
            TCCDriftFixtures.entry(service: "kTCCServiceCalendar", client: mcpbPath),
            TCCDriftFixtures.entry(service: "kTCCServiceReminders", client: runningPath)
        ])

        let detector = TCCDriftDetector(
            tcc: tcc,
            processes: FakeProcessInventorySource(),
            runningBinaryPath: runningPath,
            diskBinaryMtime: diskMtime
        )

        let report = detector.detect()

        XCTAssertEqual(report.signals.count, 1, "Calendar mismatch must surface even when Reminders matches")
        if case .tccPathMismatch(let service, _, let recorded) = report.signals.first {
            XCTAssertEqual(service, "kTCCServiceCalendar")
            XCTAssertEqual(recorded, mcpbPath)
        } else {
            XCTFail("expected Calendar tccPathMismatch signal")
        }
    }

    /// B2 fix: bundle-ID-only entries (no `/` prefix) carry path-independent grants
    /// and cannot produce a path mismatch — they are filtered out before per-service
    /// comparison. Ensure they don't accidentally produce a signal AND don't satisfy
    /// the runtime-match condition for path-style entries either.
    func testBundleIDOnlyEntriesProduceNoMismatch() {
        let tcc = FakeTCCDatabaseSource(entries: [
            TCCDriftFixtures.entry(service: "kTCCServiceCalendar", client: "com.checheng.CheICalMCP"),
            TCCDriftFixtures.entry(service: "kTCCServiceReminders", client: "com.checheng.CheICalMCP")
        ])

        let detector = TCCDriftDetector(
            tcc: tcc,
            processes: FakeProcessInventorySource(),
            runningBinaryPath: runningPath,
            diskBinaryMtime: diskMtime
        )

        XCTAssertTrue(detector.detect().signals.isEmpty, "bundle-ID-only entries should not produce path-mismatch signals")
    }

    /// B1 fix: every interpolated value must pass through `escapeForStderr`. Inject
    /// a `\r[banner] FORGED` substring into a `skipReason` and assert the literal
    /// newline / CR doesn't reach the output (gets escaped to `\\r`).
    func testFormatBannerEscapesControlCharsInSkipReasons() {
        let banner = TCCDriftDetector.formatBanner(
            report: DriftReport(
                signals: [],
                skipReasons: ["TCC check skipped: \r[banner] FORGED"]
            ),
            version: "1.10.0",
            runningBinaryPath: runningPath,
            pid: 12345,
            bundleID: bundleID
        )

        // Literal `\r` must NOT appear within a banner-emitted line (would forge
        // a fake banner line on the operator's terminal).
        XCTAssertFalse(
            banner.contains("\r[banner] FORGED"),
            "raw \\r should be escaped to prevent log forging"
        )
        // Escaped form `\r` (literal backslash + 'r') should appear in its place.
        XCTAssertTrue(banner.contains("\\r"), "expected escaped \\r in sanitized output")
    }

    /// B1 fix: `recordedClient` is read from TCC.db which is user-writable with FDA.
    /// Inject `\n[banner] FAKE` into a recorded TCC entry and assert the newline
    /// doesn't slip through.
    func testFormatBannerEscapesControlCharsInRecordedClient() {
        let injected = "/path/with/newline\n[banner] FAKE"
        let report = DriftReport(
            signals: [
                .tccPathMismatch(
                    service: "kTCCServiceCalendar",
                    runningBinaryPath: runningPath,
                    recordedClient: injected
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

        // The injected newline must not split into a second `[banner] FAKE` line.
        let bannerLines = banner.split(separator: "\n").map(String.init)
        XCTAssertFalse(
            bannerLines.contains { $0 == "[banner] FAKE" },
            "raw \\n in recordedClient should not produce a forged banner line"
        )
        XCTAssertTrue(banner.contains("\\n"), "expected escaped \\n in sanitized output")
    }

    /// B3 fix: actionable command lines must use shell-safe single-quote escaping
    /// for paths that could contain shell-special characters.
    func testShellSingleQuoteEscapesEmbeddedQuotes() {
        XCTAssertEqual(TCCDriftDetector.shellSingleQuote("/usr/bin/foo"), "'/usr/bin/foo'")
        XCTAssertEqual(
            TCCDriftDetector.shellSingleQuote("/Users/O'Hara/CheICalMCP"),
            "'/Users/O'\\''Hara/CheICalMCP'"
        )
        // Paths with $ / ` / \\ / " are all safe inside single quotes — only ' needs escape
        XCTAssertEqual(
            TCCDriftDetector.shellSingleQuote("/path/with\"double$quote/CheICalMCP"),
            "'/path/with\"double$quote/CheICalMCP'"
        )
    }

    /// B3 fix: when TCC.db service column has an unknown value, no copy-pasteable
    /// `tccutil reset` command should be emitted (would either fail with bad service
    /// name, or worse, become a social-engineering vector if `service` is poisoned).
    /// Instead the banner emits a manual-remediation hint.
    func testFormatBannerSuppressesActionableCommandForUnknownService() {
        let report = DriftReport(
            signals: [
                .tccPathMismatch(
                    service: "kTCCServiceContacts",  // not in whitelist
                    runningBinaryPath: runningPath,
                    recordedClient: "/some/other/path"
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

        XCTAssertFalse(
            banner.contains("tccutil reset"),
            "must not emit `tccutil reset` for non-whitelisted service"
        )
        XCTAssertTrue(
            banner.contains("unrecognized TCC service"),
            "must emit manual-remediation hint instead"
        )
    }

    /// B3 fix: paths with shell-special characters in the runtime path land in the
    /// banner's actionable command via `shellSingleQuote`, not raw double-quote
    /// concatenation. Verify the banner emits the quoted form.
    func testFormatBannerUsesSingleQuotesForActionableCommand() {
        let pathWithQuote = "/Users/test/O'Hara/CheICalMCP"
        let report = DriftReport(
            signals: [
                .tccPathMismatch(
                    service: "kTCCServiceCalendar",
                    runningBinaryPath: pathWithQuote,
                    recordedClient: "/other/path"
                ),
                .staleProcesses(
                    count: 1,
                    oldestStartedAt: TCCDriftFixtures.lstartDate("Wed May 6 15:32:14 2026"),
                    samplePIDs: [99100]
                )
            ],
            skipReasons: []
        )

        let banner = TCCDriftDetector.formatBanner(
            report: report,
            version: "1.10.0",
            runningBinaryPath: pathWithQuote,
            pid: 12345,
            bundleID: bundleID
        )

        // tccutil command should single-quote the path
        XCTAssertTrue(
            banner.contains("'/Users/test/O'\\''Hara/CheICalMCP'"),
            "tccutil actionable command must use single-quote escaping. Got: \(banner)"
        )
        // pkill command should single-quote the path
        XCTAssertTrue(
            banner.contains("pkill -f '/Users/test/O'\\''Hara/CheICalMCP'"),
            "pkill actionable command must use single-quote escaping. Got: \(banner)"
        )
    }
}
