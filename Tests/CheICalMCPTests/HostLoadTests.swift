import XCTest
@testable import CheICalMCP

/// #366: a timing bound overrun on a host loaded past 4 runnable tasks per core is reported as a
/// skip ("cannot judge"), and below that as a failure that names the load. The bound is the same
/// in both cases. Driven with an injected load reader.
final class HostLoadTests: XCTestCase {
    private func load(_ average: Double?, cores: Int) -> HostLoad {
        HostLoad(read: { HostLoad.Snapshot(loadAverage: average, cores: cores) })
    }

    /// A reader with the given load whose failures go to a list instead of XCTFail.
    private func recording(_ average: Double?, cores: Int) -> (load: HostLoad, failures: () -> [String]) {
        final class Box { var messages: [String] = [] }
        let box = Box()
        let load = HostLoad(read: { HostLoad.Snapshot(loadAverage: average, cores: cores) },
                            fail: { message, _, _ in box.messages.append(message) })
        return (load, { box.messages })
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
        // Below the threshold: reported through the failure sink, and nothing is thrown. Asserting
        // both pins the regression -> XCTFail mapping in `report`; an XCTExpectFailure around
        // XCTAssertNoThrow was satisfied by a thrown XCTSkip as well (#366 post-merge verify).
        let quiet = recording(1, cores: 18)
        XCTAssertNoThrow(try quiet.load.checkWithinBound(5.1, bound: 5.0, "arrival"))
        XCTAssertEqual(quiet.failures().count, 1, "below the threshold an overrun is a failure")
        let overloaded = recording(760, cores: 18)
        _ = try? overloaded.load.checkWithinBound(5.1, bound: 5.0, "arrival")
        XCTAssertEqual(overloaded.failures(), [], "a skip records no failure")
    }

    /// Exactly at the bound is over it, as with the `XCTAssertLessThan(arrival, 5.0)` it replaced.
    func testCheckWithinBoundFailsExactlyAtTheBound() {
        let quiet = recording(1, cores: 18)
        XCTAssertNoThrow(try quiet.load.checkWithinBound(5.0, bound: 5.0, "arrival"))
        XCTAssertEqual(quiet.failures().count, 1, "elapsed == bound must fail")
        let under = recording(1, cores: 18)
        XCTAssertNoThrow(try under.load.checkWithinBound(4.999, bound: 5.0, "arrival"))
        XCTAssertEqual(under.failures(), [])
    }

    func testCheckNotTimedOutThrowsASkipOnlyWhenOverloaded() throws {
        XCTAssertNoThrow(try load(760, cores: 18).checkNotTimedOut(false, bound: 15, "spawn"))
        XCTAssertThrowsError(try load(760, cores: 18).checkNotTimedOut(true, bound: 15, "spawn")) { error in
            XCTAssertTrue(error is XCTSkip, "\(error)")
        }
        let quiet = recording(1, cores: 18)
        XCTAssertNoThrow(try quiet.load.checkNotTimedOut(true, bound: 15, "spawn"))
        XCTAssertEqual(quiet.failures().count, 1, "below the threshold a timeout is a failure")
        XCTAssertTrue(quiet.failures().first?.contains("load 1.00 on 18 cores") ?? false, "\(quiet.failures())")
        let unknown = recording(nil, cores: 18)
        XCTAssertNoThrow(try unknown.load.checkNotTimedOut(true, bound: 15, "spawn"))
        XCTAssertEqual(unknown.failures().count, 1, "an unknown load is a failure, never a skip")
    }

    /// The live reader returns the 1-minute load average and the active core count. Its value is
    /// compared with a direct `getloadavg` read: a reader that over-reports (say, multiplied by the
    /// core count) would turn every real regression on the routed tests into a skip.
    func testTheLiveReaderReadsTheHost() throws {
        let snapshot = HostLoad.live.read()
        XCTAssertEqual(snapshot.cores, ProcessInfo.processInfo.activeProcessorCount)
        let live = try XCTUnwrap(snapshot.loadAverage, "getloadavg works on macOS")
        var direct = [Double](repeating: 0, count: 1)
        XCTAssertEqual(getloadavg(&direct, 1), 1)
        XCTAssertEqual(live, direct[0], accuracy: max(1.0, direct[0] * 0.25),
                       "the live reader reports the 1-minute load average as getloadavg gives it")
    }

    /// The default sink (used by `HostLoad.live`) records an XCTest failure at the caller's line.
    /// Silencing it would let every timing regression on the routed tests pass.
    func testTheDefaultSinkFailsAtTheCallersLine() throws {
        let callLine = #line + 9
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = { issue in
            issue.compactDescription.contains("load 1.00 on 18 cores")
                && !issue.compactDescription.contains("threw error")
                && issue.sourceCodeContext.location?.lineNumber == callLine
        }
        try XCTExpectFailure("below the threshold the default sink records a failure", options: options) {
            // The next line is `callLine`.
            XCTAssertNoThrow(try load(1, cores: 18).checkWithinBound(5.1, bound: 5.0, "arrival"))
        }
    }

    /// The listed timing tests go through the helper, and the bounds stay where they were: the
    /// 5.0 s banner tripwire, the 10 s spawn cap, the 15 s `--print-tcc-path` run (default and
    /// every call site). The banner spawn's timeout is checked before its stderr assertions.
    func testTheTimingTestsUseTheHelperAndKeepTheirBounds() throws {
        let tests = try SourceScan.sourcesDirectory().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/CheICalMCPTests")
        // Comments stripped, so a commented-out call does not satisfy a pin (PR #422 verify round 1).
        let banner = SourceScan.strippingComments(try String(contentsOf: tests.appendingPathComponent("TCCDriftDetectorBannerTests.swift"), encoding: .utf8))
        let disclaim = SourceScan.strippingComments(try String(contentsOf: tests.appendingPathComponent("SelfDisclaimBinaryTests.swift"), encoding: .utf8))
        let bannerTest = try XCTUnwrap(SourceScan.body(of: "func testBannerAppearsInDefaultMCPServerMode() throws {", in: banner))
        XCTAssertTrue(bannerTest.contains("try HostLoad.live.checkWithinBound(\n            arrival, bound: 5.0,"), bannerTest)
        XCTAssertEqual(bannerTest.components(separatedBy: "HostLoad.live.checkNotTimedOut(").count - 1, 2)
        // The timed spawn's timeout is judged before its stderr is asserted on: when it timed out the
        // `until` predicate (header && path) never matched, so an assertion first would record a
        // failure that the later XCTSkip cannot retract (#366 post-merge verify).
        let timeoutCheck = try XCTUnwrap(bannerTest.range(of: "HostLoad.live.checkNotTimedOut(run.timedOut"))
        let firstStderrAssert = try XCTUnwrap(bannerTest.range(of: "XCTAssertTrue(\n            run.stderr.contains(\"[banner] che-ical-mcp\")"))
        XCTAssertLessThan(timeoutCheck.lowerBound, firstStderrAssert.lowerBound,
                          "the banner spawn's timeout check must come before its stderr assertions")
        // The one stderr check allowed before it holds whatever the timing: header implies path.
        let pathCheck = try XCTUnwrap(bannerTest.range(of: "!run.stderr.contains(\"[banner] che-ical-mcp\") || run.stderr.contains(resolvedBinaryPath)"))
        XCTAssertLessThan(pathCheck.lowerBound, timeoutCheck.lowerBound, "the #129 path check runs before the timeout check")
        let warmUpCheck = try XCTUnwrap(bannerTest.range(of: "checkNotTimedOut(\n            warmUp.timedOut"))
        let warmUpStatus = try XCTUnwrap(bannerTest.range(of: "warmUp.terminationStatus"))
        XCTAssertLessThan(warmUpCheck.lowerBound, warmUpStatus.lowerBound,
                          "the warm-up's timeout check must come before its exit-status assertion")
        XCTAssertFalse(bannerTest.contains("maxWait:"), "the banner spawns use the default cap")
        // The spawn helper's own default, not any text in the file that looks like it (PR #422 verify round 1).
        let spawnParameters = try XCTUnwrap(SourceScan.arguments(of: "func spawnAndCaptureStderr(", in: banner))
        XCTAssertTrue(spawnParameters.contains("maxWait: TimeInterval = 10.0,"), "the 10 s spawn cap is unchanged")
        XCTAssertFalse(disclaim.contains("XCTAssertFalse(run.timedOut") || disclaim.contains("XCTAssertFalse(host.timedOut"))
        // #417: the seven call sites go through `checkRunBounds` (its two `checkNotTimedOut` calls:
        // the 15 s bound and the drain); `HostLoadWiringTests` pins the call sites and their order.
        XCTAssertEqual(disclaim.components(separatedBy: "HostLoad.live.checkNotTimedOut(").count - 1, 2)
        XCTAssertEqual(disclaim.components(separatedBy: "try checkRunBounds(").count - 1, 7)
        XCTAssertTrue(disclaim.contains("static let printTCCPathTimeout: TimeInterval = 15"), "the 15 s bound is unchanged")
        XCTAssertTrue(disclaim.contains("timeout: TimeInterval = printTCCPathTimeout) throws -> Run {"), "the default is that bound")
        // Every `timeout:` in the file is one of the seven known ones (runBounded's parameter and its
        // three waits, runPrintTCCPath's 15 s default and its forward, the hang test's 1 s), so no
        // call site overrides the 15 s bound, whatever its arguments look like.
        XCTAssertEqual(disclaim.components(separatedBy: "timeout:").count - 1, 7, "a new `timeout:` in SelfDisclaimBinaryTests")
        XCTAssertTrue(disclaim.contains("XCTAssertTrue(run.timedOut)"), "the hang test still expects its timeout")
    }
}
