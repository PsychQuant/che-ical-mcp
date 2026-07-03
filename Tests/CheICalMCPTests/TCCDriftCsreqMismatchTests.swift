import Foundation
import XCTest

@testable import CheICalMCP

/// Tests for the #155 csreq-mismatch drift signal — the third `DriftSignal` catching the
/// #154 silent-denial class (TCC row pins a code requirement the running binary no longer
/// satisfies; every status API reports green). Driven through `FakeCodeSignatureSource`
/// since the real running-binary signature can't be controlled in a unit test.
final class TCCDriftCsreqMismatchTests: XCTestCase {

    private let runningPath = "/Users/test/bin/CheICalMCP"

    private func makeDetector(
        entries: [TCCEntry],
        evaluation: RequirementEvaluation = .mismatch,
        hasEntitlement: Bool? = true
    ) -> TCCDriftDetector {
        TCCDriftDetector(
            tcc: FakeTCCDatabaseSource(entries: entries),
            processes: FakeProcessInventorySource(),
            runningBinaryPath: runningPath,
            diskBinaryMtime: nil,
            codeSignature: FakeCodeSignatureSource(evaluation: evaluation, hasEntitlement: hasEntitlement)
        )
    }

    /// Extract (service, hasEntitlement) tuples for every csreqMismatch signal in a report.
    private func csreqSignals(_ report: DriftReport) -> [(service: String, hasEntitlement: Bool?)] {
        report.signals.compactMap {
            if case .csreqMismatch(let service, let ent) = $0 { return (service, ent) }
            return nil
        }
    }

    // MARK: - detect()

    func testCsreqMismatch_emitsSignal() {
        // client == runningPath so NO path-mismatch signal fires — isolates the csreq signal
        // (the realistic #154 shape: path still matches, but csreq pins an old cdhash).
        let report = makeDetector(
            entries: [TCCDriftFixtures.entry(client: runningPath, csreqHex: "DEADBEEF")]
        ).detect()

        let signals = csreqSignals(report)
        XCTAssertEqual(signals.count, 1, "one Calendar csreq-mismatch signal expected")
        XCTAssertEqual(signals.first?.service, "kTCCServiceCalendar")
        XCTAssertEqual(signals.first?.hasEntitlement, true)
    }

    func testCsreqSatisfies_noSignal() {
        let report = makeDetector(
            entries: [TCCDriftFixtures.entry(client: runningPath, csreqHex: "DEADBEEF")],
            evaluation: .satisfies
        ).detect()
        XCTAssertTrue(csreqSignals(report).isEmpty, "a satisfied requirement must not emit a signal")
    }

    func testCsreqUndecidable_noSignalButSkipReason() {
        let report = makeDetector(
            entries: [TCCDriftFixtures.entry(client: runningPath, csreqHex: "DEADBEEF")],
            evaluation: .undecidable(reason: "SecCodeCheckValidity OSStatus -67062")
        ).detect()
        XCTAssertTrue(csreqSignals(report).isEmpty, "undecidable must NEVER be classified as drift (no cry-wolf)")
        XCTAssertTrue(
            report.skipReasons.contains { $0.contains("csreq check skipped") },
            "undecidable should surface a skip reason, not silence"
        )
    }

    func testMissingCsreq_notEvaluated() {
        // No csreqHex → the row is filtered out before the signature check runs.
        let report = makeDetector(
            entries: [TCCDriftFixtures.entry(client: runningPath, csreqHex: nil)],
            evaluation: .mismatch
        ).detect()
        XCTAssertTrue(csreqSignals(report).isEmpty, "rows without a pinned csreq are not evaluated")
    }

    func testEntitlementMissing_annotatedInSignal() {
        let report = makeDetector(
            entries: [TCCDriftFixtures.entry(client: runningPath, csreqHex: "DEADBEEF")],
            hasEntitlement: false
        ).detect()
        XCTAssertEqual(csreqSignals(report).first?.hasEntitlement, false,
            "missing personal-information entitlement must be annotated on the signal")
    }

    func testEntitlementUnreadable_annotatedNil() {
        let report = makeDetector(
            entries: [TCCDriftFixtures.entry(client: runningPath, csreqHex: "DEADBEEF")],
            hasEntitlement: nil
        ).detect()
        XCTAssertEqual(csreqSignals(report).first?.hasEntitlement, nil,
            "unreadable entitlements should annotate as nil, not fabricate a value")
    }

    func testPerServiceMismatch_multipleSignals() {
        let report = makeDetector(entries: [
            TCCDriftFixtures.entry(service: "kTCCServiceCalendar", client: runningPath, csreqHex: "AA"),
            TCCDriftFixtures.entry(service: "kTCCServiceReminders", client: runningPath, csreqHex: "BB"),
        ]).detect()
        let services = Set(csreqSignals(report).map(\.service))
        XCTAssertEqual(services, ["kTCCServiceCalendar", "kTCCServiceReminders"],
            "each mismatched service gets its own signal")
    }

    func testMostRecentRowWinsPerService() {
        // Two Calendar rows both pinning a csreq → exactly one signal (most-recent chosen).
        let report = makeDetector(entries: [
            TCCDriftFixtures.entry(client: runningPath, lastModifiedUnix: 1_000, csreqHex: "AA"),
            TCCDriftFixtures.entry(client: runningPath, lastModifiedUnix: 2_000, csreqHex: "BB"),
        ]).detect()
        XCTAssertEqual(csreqSignals(report).count, 1, "one signal per service, not per row")
    }

    // MARK: - dataFromHex

    func testDataFromHex_valid() {
        XCTAssertEqual(TCCDriftDetector.dataFromHex("DEADBEEF"), Data([0xDE, 0xAD, 0xBE, 0xEF]))
        XCTAssertEqual(TCCDriftDetector.dataFromHex("deadbeef"), Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    func testDataFromHex_rejectsMalformed() {
        XCTAssertNil(TCCDriftDetector.dataFromHex("ABC"), "odd-length hex is malformed")
        XCTAssertNil(TCCDriftDetector.dataFromHex("ZZ"), "non-hex digits are malformed")
        XCTAssertNil(TCCDriftDetector.dataFromHex(""), "empty is not a valid blob")
    }

    // MARK: - Banner formatting

    func testBanner_csreqMismatch_missingEntitlement() {
        let report = DriftReport(
            signals: [.csreqMismatch(service: "kTCCServiceCalendar", hasEntitlement: false)],
            skipReasons: []
        )
        let banner = TCCDriftDetector.formatBanner(
            report: report, version: "1.13.0", runningBinaryPath: runningPath,
            pid: 4242, bundleID: "com.checheng.CheICalMCP"
        )
        XCTAssertTrue(banner.contains("Calendar entry pins a code requirement this binary no longer satisfies"))
        XCTAssertTrue(banner.contains("silent denial"))
        XCTAssertTrue(banner.contains("policy-blocked"), "missing-entitlement note must show when hasEntitlement=false")
        XCTAssertTrue(banner.contains("tccutil reset Calendar com.checheng.CheICalMCP"))
        XCTAssertTrue(banner.contains("drift detected (1 signal)"))
    }

    func testBanner_csreqMismatch_hasEntitlement_omitsPolicyBlockLine() {
        let report = DriftReport(
            signals: [.csreqMismatch(service: "kTCCServiceCalendar", hasEntitlement: true)],
            skipReasons: []
        )
        let banner = TCCDriftDetector.formatBanner(
            report: report, version: "1.13.0", runningBinaryPath: runningPath,
            pid: 4242, bundleID: "com.checheng.CheICalMCP"
        )
        XCTAssertTrue(banner.contains("no longer satisfies"))
        XCTAssertFalse(banner.contains("lacks the personal-information entitlement"),
            "the policy-blocked note must NOT show when the binary has the entitlement")
    }

    func testBanner_csreqMismatch_unknownService_noBadCommand() {
        // Poisoned/unknown service must not yield a copy-paste `tccutil reset <bad>` command.
        let report = DriftReport(
            signals: [.csreqMismatch(service: "kTCCServiceBogus", hasEntitlement: false)],
            skipReasons: []
        )
        let banner = TCCDriftDetector.formatBanner(
            report: report, version: "1.13.0", runningBinaryPath: runningPath,
            pid: 4242, bundleID: "com.checheng.CheICalMCP"
        )
        XCTAssertFalse(banner.contains("tccutil reset kTCCServiceBogus"))
        XCTAssertTrue(banner.contains("manual remediation"))
    }
}
