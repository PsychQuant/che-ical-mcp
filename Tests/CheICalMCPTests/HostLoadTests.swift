import XCTest
@testable import CheICalMCP

/// #366: a timing bound overrun on a host loaded past 4 runnable tasks per core is reported as a
/// skip ("cannot judge"), and below that as a failure that names the load. The bound is the same
/// in both cases. Driven with an injected load reader.
final class HostLoadTests: XCTestCase {
    private func load(_ average: Double?, cores: Int) -> HostLoad {
        HostLoad(read: { HostLoad.Snapshot(loadAverage: average, cores: cores) })
    }

    func testTheRatioIsLoadPerCore() {
        XCTAssertEqual(HostLoad.Snapshot(loadAverage: 72, cores: 18).perCore, 4)
        XCTAssertNil(HostLoad.Snapshot(loadAverage: nil, cores: 18).perCore, "getloadavg failed: no ratio")
        XCTAssertNil(HostLoad.Snapshot(loadAverage: 10, cores: 0).perCore)
    }

    func testWithinTheBoundPassesWhateverTheLoad() {
        for snapshot in [HostLoad.Snapshot(loadAverage: 760, cores: 18), .init(loadAverage: 1, cores: 18)] {
            XCTAssertEqual(HostLoad.verdict(exceeded: false, what: "x", snapshot: snapshot), .withinBound)
        }
    }

    /// The reported failures were at ratios of about 7 to 42 on 18 cores.
    func testAnOverrunOnAnOverloadedHostCannotBeJudged() {
        let verdict = HostLoad.verdict(exceeded: true, what: "banner arrival 6.200 s, bound 5.0 s",
                                       snapshot: .init(loadAverage: 130, cores: 18))
        guard case .cannotJudge(let message) = verdict else { return XCTFail("\(verdict)") }
        XCTAssertTrue(message.contains("banner arrival 6.200 s, bound 5.0 s"), message)
        XCTAssertTrue(message.contains("load 130.00 on 18 cores"), message)
        XCTAssertTrue(message.contains("7.22 per core"), message)
        XCTAssertTrue(message.contains("cannot judge"), message)
    }

    func testAnOverrunBelowTheThresholdIsARegressionThatNamesTheLoad() {
        let verdict = HostLoad.verdict(exceeded: true, what: "spawn timed out, bound 15 s",
                                       snapshot: .init(loadAverage: 9, cores: 18))
        guard case .regression(let message) = verdict else { return XCTFail("\(verdict)") }
        XCTAssertTrue(message.contains("spawn timed out, bound 15 s"), message)
        XCTAssertTrue(message.contains("load 9.00 on 18 cores"), message)
        XCTAssertTrue(message.contains("0.50 per core"), message)
    }

    /// Exactly at the threshold is not "exceeds": it still fails.
    func testTheThresholdItselfStillFails() {
        guard case .regression = HostLoad.verdict(exceeded: true, what: "x", snapshot: .init(loadAverage: 72, cores: 18)) else {
            return XCTFail("ratio 4.0 must fail")
        }
        guard case .cannotJudge = HostLoad.verdict(exceeded: true, what: "x", snapshot: .init(loadAverage: 72.1, cores: 18)) else {
            return XCTFail("ratio above 4.0 must skip")
        }
    }

    /// No load reading (getloadavg failed): the overrun fails, never a skip.
    func testAnUnknownLoadFails() {
        guard case .regression(let message) = HostLoad.verdict(exceeded: true, what: "x", snapshot: .init(loadAverage: nil, cores: 18)) else {
            return XCTFail("unknown load must fail")
        }
        XCTAssertTrue(message.contains("load unknown"), message)
    }

    func testCheckWithinBoundThrowsASkipOnlyWhenOverloaded() throws {
        XCTAssertNoThrow(try load(760, cores: 18).checkWithinBound(4.9, bound: 5.0, "arrival"))
        XCTAssertThrowsError(try load(760, cores: 18).checkWithinBound(5.1, bound: 5.0, "arrival")) { error in
            XCTAssertTrue(error is XCTSkip, "\(error)")
        }
        try XCTExpectFailure("below the threshold an overrun is a failure") {
            XCTAssertNoThrow(try load(1, cores: 18).checkWithinBound(5.1, bound: 5.0, "arrival"))
        }
    }

    func testCheckNotTimedOutThrowsASkipOnlyWhenOverloaded() throws {
        XCTAssertNoThrow(try load(760, cores: 18).checkNotTimedOut(false, bound: 15, "spawn"))
        XCTAssertThrowsError(try load(760, cores: 18).checkNotTimedOut(true, bound: 15, "spawn")) { error in
            XCTAssertTrue(error is XCTSkip, "\(error)")
        }
        try XCTExpectFailure("below the threshold a timeout is a failure") {
            XCTAssertNoThrow(try load(1, cores: 18).checkNotTimedOut(true, bound: 15, "spawn"))
        }
    }

    /// The live reader returns the 1-minute load average and the active core count.
    func testTheLiveReaderReadsTheHost() {
        let snapshot = HostLoad.live.read()
        XCTAssertEqual(snapshot.cores, ProcessInfo.processInfo.activeProcessorCount)
        XCTAssertNotNil(snapshot.loadAverage, "getloadavg works on macOS")
    }

    /// The listed timing tests go through the helper, and the bounds stay where they were: the
    /// 5.0 s banner tripwire, the 10 s spawn cap, the 15 s `--print-tcc-path` run.
    func testTheTimingTestsUseTheHelperAndKeepTheirBounds() throws {
        let tests = try SourceScan.sourcesDirectory().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/CheICalMCPTests")
        let banner = try String(contentsOf: tests.appendingPathComponent("TCCDriftDetectorBannerTests.swift"), encoding: .utf8)
        let disclaim = try String(contentsOf: tests.appendingPathComponent("SelfDisclaimBinaryTests.swift"), encoding: .utf8)
        let bannerTest = try XCTUnwrap(SourceScan.body(of: "func testBannerAppearsInDefaultMCPServerMode() throws {", in: banner))
        XCTAssertTrue(bannerTest.contains("try HostLoad.live.checkWithinBound(\n            arrival, bound: 5.0,"), bannerTest)
        XCTAssertEqual(bannerTest.components(separatedBy: "HostLoad.live.checkNotTimedOut(").count - 1, 2)
        XCTAssertFalse(disclaim.contains("XCTAssertFalse(run.timedOut") || disclaim.contains("XCTAssertFalse(host.timedOut"))
        XCTAssertEqual(disclaim.components(separatedBy: "HostLoad.live.checkNotTimedOut(").count - 1, 7)
        XCTAssertTrue(disclaim.contains("timeout: TimeInterval = 15) throws -> Run {"), "the 15 s bound is unchanged")
        XCTAssertTrue(disclaim.contains("XCTAssertTrue(run.timedOut)"), "the hang test still expects its timeout")
    }
}
