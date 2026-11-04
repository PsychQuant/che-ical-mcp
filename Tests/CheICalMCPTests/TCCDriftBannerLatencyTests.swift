import Foundation
import XCTest

@testable import CheICalMCP

/// #266 — the startup banner's 200 ms latency target (#127), encoded at the unit level.
///
/// The spawn-level test (`TCCDriftDetectorBannerTests.testBannerAppearsInDefaultMCPServerMode`)
/// can only hold a coarse 5 s tripwire (#233): spawning a binary on a loaded CI runner takes
/// seconds. The tight bound lives here instead, in process: `detect()` + `formatBanner` with the
/// four sources replaced by fakes, so no subprocess, EventKit or TCC is involved. The live
/// sources' subprocess cost (sqlite3, ps) is a different budget and stays with the spawn tripwire.
///
/// `formatBanner` alone runs in microseconds, so timing it alone would catch nothing; the fixture
/// below makes `detect()` emit four signal kinds (TCC path mismatch and code-requirement mismatch
/// for both services, stale processes past the PID list limit, host attribution of an ungranted
/// host) and `formatBanner` print their lines (asserted in
/// `testWorstCaseFixtureReachesFourSignalKindsAndTheirLines`, so a short-circuit cannot make the
/// timing pass trivially). Not reached: the restricted-host signal, skip reasons and the
/// Calendar-not-granted line (a host signal suppresses it).
///
/// Measured on an M5 Max (2026-11-04, Debug build; the median test run 20 times while a full
/// `TZ=UTC swift test` ran beside it): the median of the 15 timed runs was 0.087–0.112 ms. 200 ms
/// is kept as the bound (#266 allows "a target justified against measured cost"): it is the #127
/// target, and with a margin of about 2000 times a trip is a real regression, not scheduler noise.
/// A 250 ms sleep added to `detect()` turned `testBannerBuildMedianIsUnderTheTarget` red
/// (median 0.254 s).
final class TCCDriftBannerLatencyTests: XCTestCase {

    private let runningPath = "/Users/test/bin/CheICalMCP"

    /// The #127 target.
    private let latencyTarget: Duration = .milliseconds(200)

    // MARK: - Fixture

    /// Several TCC rows per service, none matching the running path, each pinning a csreq; more
    /// stale processes than `stalePIDListLimit`; a host as the responsible process; Calendar and
    /// Reminders both ungranted.
    private func worstCaseDetector(tcc: TCCDatabaseSource? = nil) -> TCCDriftDetector {
        let services = ["kTCCServiceCalendar", "kTCCServiceReminders"]
        let entries: [TCCEntry] = services.flatMap { service in
            (0..<8).map { i in
                TCCDriftFixtures.entry(
                    service: service,
                    client: "/Users/test/old-\(i)/CheICalMCP",
                    lastModifiedUnix: 1_748_774_595 + Int64(i),
                    csreqHex: "FADE0C00000000\(String(format: "%02X", i))"
                )
            }
        }
        let cutoff = TCCDriftFixtures.lstartDate("Mon May 11 22:36:52 2026")
        // `detect()` drops the test process's own PID, so the 40 PIDs skip it: otherwise one could
        // equal it and the "(+ 35 more)" count would be off by one (PR #389 round 2).
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let pids = Array((Int32(80_000)..<Int32(80_041)).filter { $0 != ownPID }.prefix(40))
        let stale: [RunningProcess] = pids.enumerated().map { i, pid in
            TCCDriftFixtures.process(pid: pid, startedAt: cutoff.addingTimeInterval(-Double(i + 1) * 60))
        }
        return TCCDriftDetector(
            tcc: tcc ?? FakeTCCDatabaseSource(entries: entries),
            processes: FakeProcessInventorySource(processes: stale),
            runningBinaryPath: runningPath,
            diskBinaryMtime: cutoff,
            stalePIDListLimit: 5,
            codeSignature: FakeCodeSignatureSource(evaluation: .mismatch, hasEntitlement: false),
            responsibleProcess: FakeResponsibleProcessSource(result: .resolved(ResponsibleProcess(
                pid: 4242, path: "/Users/test/.local/share/claude/versions/2.1.206", isSelf: false))),
            eventKitAccessGranted: false,
            eventKitRestricted: false
        )
    }

    /// The banner-building work `emitStartupBanner()` does after the status reads.
    private func buildBanner(_ detector: TCCDriftDetector) -> String {
        TCCDriftDetector.formatBanner(
            report: detector.detect(),
            version: "9.9.9",
            runningBinaryPath: runningPath,
            pid: 4242,
            bundleID: "com.checheng.CheICalMCP",
            calendarAccessGranted: false,
            calendarRestricted: false,
            remindersStatus: .denied
        )
    }

    // MARK: - Tests

    func testWorstCaseFixtureReachesFourSignalKindsAndTheirLines() {
        let detector = worstCaseDetector()
        let report = detector.detect()
        var kinds: Set<String> = []
        for signal in report.signals {
            switch signal {
            case .tccPathMismatch: kinds.insert("path")
            case .csreqMismatch: kinds.insert("csreq")
            case .staleProcesses: kinds.insert("stale")
            case .hostAttributedUngranted: kinds.insert("host")
            default: kinds.insert("other")
            }
        }
        XCTAssertEqual(kinds, ["path", "csreq", "stale", "host"])
        XCTAssertEqual(report.signals.count, 2 + 2 + 1 + 1, "two services x (path + csreq), stale, host")

        let banner = buildBanner(detector)
        XCTAssertTrue(banner.contains("entry path mismatch"))
        XCTAssertTrue(banner.contains("pins a code requirement"))
        XCTAssertTrue(banner.contains("[drift] 40 stale CheICalMCP processes running"), banner)
        XCTAssertTrue(banner.contains("(+ 35 more)"), "more stale PIDs than the list limit")
        XCTAssertTrue(banner.contains("macOS checks a host instead of CheICalMCP"))
    }

    func testBannerBuildMedianIsUnderTheTarget() {
        let detector = worstCaseDetector()
        let median = BannerLatency.median(runs: 15) { _ = buildBanner(detector) }
        XCTAssertLessThan(median, latencyTarget,
                          "median banner build \(median) exceeds the #127 target \(latencyTarget)")
    }

    /// The measurement can see a slow source: one that sleeps past the target per call makes the
    /// median reach the target, so `testBannerBuildMedianIsUnderTheTarget` would go red if
    /// `detect()` ever started doing that much work.
    func testMedianCatchesASlowSource() {
        let slow = SlowTCCDatabaseSource(delay: .milliseconds(210))
        let detector = worstCaseDetector(tcc: slow)
        let median = BannerLatency.median(runs: 3) { _ = buildBanner(detector) }
        XCTAssertGreaterThanOrEqual(median, latencyTarget)
    }

    func testMedianOfOddAndEvenSamples() {
        XCTAssertEqual(BannerLatency.median(of: [.milliseconds(5), .milliseconds(1), .milliseconds(3)]),
                       .milliseconds(3))
        XCTAssertEqual(BannerLatency.median(of: [.milliseconds(4), .milliseconds(1), .milliseconds(2), .milliseconds(8)]),
                       .milliseconds(3))
    }
}

/// A TCC source that blocks for `delay` before answering, standing in for a detector that has
/// started doing expensive work.
private struct SlowTCCDatabaseSource: TCCDatabaseSource {
    let delay: Duration

    func readCheICalMCPEntries() -> TCCQueryResult {
        let (seconds, attoseconds) = delay.components
        Thread.sleep(forTimeInterval: Double(seconds) + Double(attoseconds) / 1e18)
        return TCCQueryResult(entries: [], failureReason: nil)
    }
}
