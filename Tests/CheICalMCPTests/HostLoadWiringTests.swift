import XCTest

/// #417: every wall-clock bound in the test suite is judged through `HostLoad` (an overrun on a
/// host loaded past 4 runnable tasks per core is a skip, otherwise a failure naming the load), with
/// its bound value unchanged, and before any assertion that reads the child's output: an `XCTSkip`
/// cannot retract a failure recorded earlier (#366 post-merge verify, #418). Source pins over the
/// test files. The deliberate exceptions: assertions that a timeout *did* happen (load can only
/// make them more certain), lower bounds, and `LiveProcessInventorySourceTests`' 10 s `ps` budget
/// (#315), which is a budget handed to production code.
final class HostLoadWiringTests: XCTestCase {
    private func testFile(_ name: String) throws -> String {
        let tests = try SourceScan.sourcesDirectory().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/CheICalMCPTests")
        return try String(contentsOf: tests.appendingPathComponent(name), encoding: .utf8)
    }

    private func body(_ declaration: String, in source: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTUnwrap(SourceScan.body(of: declaration, in: source), declaration, file: file, line: line)
    }

    /// `first` occurs in `text`, and before every occurrence of each of `later`.
    private func assertFirst(_ first: String, before later: [String], in text: String, _ name: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let check = text.range(of: first) else {
            return XCTFail("\(name): no \(first)", file: file, line: line)
        }
        for marker in later {
            if let use = text.range(of: marker) {
                XCTAssertLessThan(check.lowerBound, use.lowerBound, "\(name): \(first) must come before \(marker)", file: file, line: line)
            }
        }
    }

    func testTheBannerSpawnsJudgeTheirCapsAndDrainsFirst() throws {
        let source = try testFile("TCCDriftDetectorBannerTests.swift")
        XCTAssertFalse(source.contains("XCTAssertFalse(run.timedOut"), "an exits-by-itself check outside HostLoad")
        XCTAssertTrue(source.contains("maxWait: TimeInterval = 10.0,"), "the 10 s spawn cap is unchanged")
        XCTAssertTrue(source.contains("static let drainCap: TimeInterval = 1.0"), "the 1 s drain cap is unchanged")
        XCTAssertTrue(source.contains("drainDone.wait(timeout: .now() + Self.drainCap) == .timedOut"))
        XCTAssertTrue(source.contains("stdoutDrainDone.wait(timeout: .now() + Self.drainCap) == .timedOut"))
        let helper = try body("private func checkSpawnBounds(", in: source)
        XCTAssertTrue(helper.contains("HostLoad.live.checkNotTimedOut(run.timedOut, bound: maxWait"), helper)
        XCTAssertTrue(helper.contains("HostLoad.live.checkNotTimedOut(run.drainTimedOut, bound: Self.drainCap"), helper)

        let reads = ["run.stderr", "run.terminationStatus", "run.untilMatchedAfter", "XCTAssertTrue(run.timedOut"]
        for name in ["testSpawnHelperCapturesChildThatWritesAfterOneSecond", "testSpawnHelperReturnsOnceUntilPredicateMatches",
                     "testSpawnHelperReportsTimeoutWhenChildOutlivesTheCap", "testBannerIsEmittedExactlyOnceAfterTheReexec",
                     "testBannerSuppressedByEnvironmentVariable", "testNoBannerForVersionFlag", "testNoBannerForHelpFlag",
                     "testBannerHandlesArbitraryBinaryPath"] {
            assertFirst("try checkSpawnBounds(run", before: reads, in: try body("func \(name)() throws {", in: source), name)
        }
        let until = try body("func testSpawnHelperReturnsOnceUntilPredicateMatches() throws {", in: source)
        XCTAssertTrue(until.contains("try HostLoad.live.checkWithinBound(elapsed, bound: 5.0,"), until)
        assertFirst("try HostLoad.live.checkWithinBound(elapsed, bound: 5.0,", before: reads, in: until, "until")
        let cap = try body("func testSpawnHelperReportsTimeoutWhenChildOutlivesTheCap() throws {", in: source)
        XCTAssertTrue(cap.contains("try HostLoad.live.checkWithinBound(elapsed, bound: 3.0,"), cap)
        XCTAssertTrue(cap.contains("try checkSpawnBounds(run, exitsBySelf: false,"), "the capped child is not expected to exit")
        let arbitrary = try body("func testBannerHandlesArbitraryBinaryPath() throws {", in: source)
        XCTAssertTrue(arbitrary.contains("try checkSpawnBounds(run, maxWait: 10.0,"), "the explicit 10 s budget is kept")
        // The timed banner test keeps its #366 order, and judges the drain before reading stderr.
        let banner = try body("func testBannerAppearsInDefaultMCPServerMode() throws {", in: source)
        assertFirst("try checkSpawnBounds(run, exitsBySelf: false,",
                    before: ["XCTAssertTrue(\n            run.stderr.contains(\"[banner] che-ical-mcp\")", "run.untilMatchedAfter"],
                    in: banner, "banner")
        assertFirst("try checkSpawnBounds(warmUp, exitsBySelf: false,", before: ["warmUp.terminationStatus"], in: banner, "warm-up")
    }

    func testTheSelfDisclaimRunsJudgeTheirCapAndDrainFirst() throws {
        let source = try testFile("SelfDisclaimBinaryTests.swift")
        XCTAssertTrue(source.contains("static let printTCCPathTimeout: TimeInterval = 15"), "the 15 s bound is unchanged")
        XCTAssertTrue(source.contains("static let drainCap: TimeInterval = 5"), "the 5 s drain cap is unchanged")
        XCTAssertTrue(source.contains("drained.wait(timeout: .now() + Self.drainCap) == .timedOut"))
        XCTAssertFalse(source.contains("XCTAssertLessThan(run.elapsed"))
        let helper = try body("private func checkRunBounds(", in: source)
        XCTAssertTrue(helper.contains("HostLoad.live.checkNotTimedOut(run.timedOut, bound: Self.printTCCPathTimeout"), helper)
        XCTAssertTrue(helper.contains("HostLoad.live.checkNotTimedOut(run.drainTimedOut, bound: Self.drainCap"), helper)
        XCTAssertEqual(source.components(separatedBy: "try checkRunBounds(").count - 1, 7)
        for name in ["testForcedDisclaim_reexecsAsItsOwnResponsibleProcessKeepingThePid", "testForcedDisclaim_saysSoOnStderr",
                     "testOptOut_keepsTheHostAsTheResponsibleProcess", "testSentinelAlreadySet_doesNotReexecAgain_andSaysItHadNoEffect",
                     "testPrintTCCPath_singleQuotesItsCommands"] {
            assertFirst("try checkRunBounds(run", before: ["run.stdout", "run.stderr", "run.status", "skipIfThePolicyKeptTheHost(run)"],
                        in: try body("func \(name)() throws {", in: source), name)
        }
        let status = try body("func testDefault_followsTheHostsAuthorizationStatus() throws {", in: source)
        assertFirst("try checkRunBounds(host", before: ["host.stdout"], in: status, "oracle")
        assertFirst("try checkRunBounds(run", before: ["run.stdout", "run.status"], in: status, "status run")
        let hang = try body("func testAHungChildIsKilledAtTheBound_notWaitedOnForever() throws {", in: source)
        XCTAssertTrue(hang.contains("XCTAssertTrue(run.timedOut)"), "the hang test still expects its timeout")
        XCTAssertTrue(hang.contains("try HostLoad.live.checkWithinBound(run.elapsed, bound: 10,"), hang)
    }

    func testThePrintTCCPathThroughPATHRunJudgesBeforeReading() throws {
        let test = try body("func testBareArgv0ThroughPATH_namesTheBinaryTheKernelRan_notAFileInTheCurrentDirectory() throws {",
                            in: try testFile("PrintTCCPathBinaryTests.swift"))
        XCTAssertTrue(test.contains("let timedOut = exited.wait(timeout: .now() + 20) == .timedOut"), test)
        XCTAssertTrue(test.contains("let drainTimedOut = drained.wait(timeout: .now() + 3) == .timedOut"), test)
        XCTAssertFalse(test.contains("XCTFail(\"--print-tcc-path did not exit"), test)
        assertFirst("try HostLoad.live.checkNotTimedOut(timedOut, bound: 20,", before: ["let text ="], in: test, "cap")
        assertFirst("try HostLoad.live.checkNotTimedOut(drainTimedOut, bound: 3,", before: ["let text ="], in: test, "drain")
    }

    func testTheInProcessBoundsGoThroughTheHelper() throws {
        let tags = try body("func testAdversarialLineIsReturnedUnchanged() throws {", in: try testFile("ReminderTagsTests.swift"))
        XCTAssertTrue(tags.contains("try HostLoad.live.checkWithinBound(Date().timeIntervalSince(start), bound: 1,"), tags)
        XCTAssertFalse(tags.contains("XCTAssertLessThan(Date()"), tags)

        let chain = try body("func testTimeout_reportsTimedOutAndEndsTheChild() throws {", in: try testFile("LiveParentChainSourceTests.swift"))
        XCTAssertTrue(chain.contains("try HostLoad.live.checkWithinBound(Date().timeIntervalSince(started), bound: 10,"), chain)
        XCTAssertFalse(chain.contains("XCTAssertLessThan(Date()"), chain)

        let transport = try testFile("DrainingStdioTransportTests.swift")
        XCTAssertFalse(transport.contains("XCTAssertLessThan(elapsed, .seconds(5)") || transport.contains("XCTAssertLessThan(clock.now - start"),
                       "an upper time bound outside HostLoad")
        XCTAssertEqual(transport.components(separatedBy: "try checkUnder5Seconds(").count - 1, 5)
        let waitUntil = try body("private func waitUntil(", in: transport)
        XCTAssertTrue(waitUntil.contains("HostLoad.live.checkNotTimedOut(true, bound: 5,"), waitUntil)

        let inventory = try testFile("LiveProcessInventorySourceTests.swift")
        XCTAssertTrue(inventory.contains("static let generousTimeoutMilliseconds = 10_000"), "the #315 budget is unchanged")
        XCTAssertTrue(inventory.contains("deliberate exception (#417)"), "the exception is named in the file")
    }

    func testTheStdioDrainSpawnsJudgeTheirCapAndDrainFirst() throws {
        let source = try testFile("StdioEOFDrainTests.swift")
        XCTAssertTrue(source.contains("maxWait: TimeInterval = 20) throws -> Run {"), "the 20 s cap is unchanged")
        XCTAssertTrue(source.contains("static let drainCap: TimeInterval = 3"), "the 3 s drain cap is unchanged")
        XCTAssertFalse(source.contains("XCTAssertTrue(run.exitedBySelf"))
        XCTAssertFalse(source.contains("XCTAssertLessThan(run.seconds"))
        let helper = try body("private func checkRunBounds(", in: source)
        XCTAssertTrue(helper.contains("HostLoad.live.checkNotTimedOut(!run.exitedBySelf, bound: maxWait"), helper)
        XCTAssertTrue(helper.contains("HostLoad.live.checkNotTimedOut(run.drainTimedOut, bound: Self.drainCap"), helper)
        for name in ["testARequestReadBeforeEOFIsAnswered", "testEveryRequestReadBeforeEOFIsAnswered",
                     "testALargeIntegerIdReadBeforeEOFIsAnswered", "testABatchReadBeforeEOFIsAnswered",
                     "testWithNoRequestEOFStillEndsTheServer"] {
            assertFirst("try checkRunBounds(run", before: ["run.stdoutLines", "run.terminationStatus"],
                        in: try body("func \(name)() throws {", in: source), name)
        }
        let idle = try body("func testWithNoRequestEOFStillEndsTheServer() throws {", in: source)
        XCTAssertTrue(idle.contains("try HostLoad.live.checkWithinBound(run.seconds, bound: 10,"), idle)
    }
}
