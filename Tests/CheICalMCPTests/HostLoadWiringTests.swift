import XCTest

/// #417: every wall-clock upper bound in the test suite is judged through `HostLoad` (an overrun on
/// a host loaded past 4 runnable tasks per core is a skip, otherwise a failure naming the load),
/// with its bound value unchanged, and placed where `HostLoad`'s doc says: before any assertion
/// that reads output the bound protects (an `XCTSkip` cannot retract a failure recorded earlier,
/// #366 post-merge verify, #418), after assertions whose input is complete either way, and with
/// cleanup that a skip must not bypass registered as teardown. Source pins over the test files,
/// read with comments stripped so a commented-out call does not satisfy them (PR #422 verify
/// round 1).
///
/// The deliberate exceptions, each named in its file:
/// - assertions that a timeout *did* happen (load can only make them more certain);
/// - lower bounds (`>= 300 ms`, the slow-source median);
/// - the 10 s budgets handed to production code by `LiveProcessInventorySourceTests` (#315),
///   `LiveTCCDatabaseSourceTests` (#315) and `LiveParentChainSourceTests` (#257): an overrun there
///   is the source's own `failureReason`, not a test's bound;
/// - the #129 header-implies-path check in the timed banner test, which keeps its #366 place
///   before the timeout check (the banner is one `write(2)`, whole or absent).
final class HostLoadWiringTests: XCTestCase {
    private func testFile(_ name: String) throws -> String {
        let tests = try SourceScan.sourcesDirectory().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/CheICalMCPTests")
        return SourceScan.strippingComments(try String(contentsOf: tests.appendingPathComponent(name), encoding: .utf8))
    }

    private func body(_ declaration: String, in source: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTUnwrap(SourceScan.body(of: declaration, in: source), declaration, file: file, line: line)
    }

    private func arguments(_ call: String, in source: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTUnwrap(SourceScan.arguments(of: call, in: source), call, file: file, line: line)
    }

    /// `first` occurs in `text`, and before every occurrence of each of `later`.
    private func assertFirst(_ first: String, before later: [String], in text: String, _ name: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let check = text.range(of: first) else {
            return XCTFail("\(name): no \(first)", file: file, line: line)
        }
        for marker in later {
            var searchFrom = text.startIndex
            while let use = text.range(of: marker, range: searchFrom..<text.endIndex) {
                XCTAssertLessThan(check.lowerBound, use.lowerBound, "\(name): \(first) must come before \(marker)", file: file, line: line)
                searchFrom = use.upperBound
            }
        }
    }

    // MARK: - Banner spawns

    func testTheBannerSpawnsJudgeTheirCapsAndDrainsFirst() throws {
        let source = try testFile("TCCDriftDetectorBannerTests.swift")
        XCTAssertFalse(source.contains("XCTAssertFalse(run.timedOut"), "an exits-by-itself check outside HostLoad")
        XCTAssertFalse(source.contains("XCTAssertLessThan(elapsed") || source.contains("XCTAssertLessThan(arrival"),
                       "a raw upper time bound beside the HostLoad checks")
        XCTAssertTrue(source.contains("static let drainCap: TimeInterval = 1.0"), "the 1 s drain cap is unchanged")

        // The cap: the spawn helper's own default, and the result carries the cap it ran with.
        let spawn = try arguments("func spawnAndCaptureStderr(", in: source)
        XCTAssertTrue(spawn.contains("maxWait: TimeInterval = 10.0,"), "the 10 s spawn cap is unchanged")
        let spawnBody = try body("func spawnAndCaptureStderr(", in: source)
        XCTAssertTrue(spawnBody.contains("let stderrDrainTimedOut = drainDone.wait(timeout: .now() + Self.drainCap) == .timedOut"))
        XCTAssertTrue(spawnBody.contains("let stdoutDrainTimedOut = stdoutDrainDone.wait(timeout: .now() + Self.drainCap) == .timedOut"))
        XCTAssertTrue(spawnBody.contains("maxWait: maxWait,"), "the result reports the cap the spawn used")
        XCTAssertTrue(spawnBody.contains("drainTimedOut: stderrDrainTimedOut || stdoutDrainTimedOut"), "both drains reach the result")

        // The check: no cap of its own; it reads the run's, and the exits-by-itself branch is live.
        XCTAssertFalse(try arguments("private func checkSpawnBounds(", in: source).contains("maxWait"))
        let helper = try body("private func checkSpawnBounds(", in: source)
        XCTAssertTrue(helper.contains("if exitsBySelf {\n            try HostLoad.live.checkNotTimedOut(run.timedOut, bound: run.maxWait,"), helper)
        XCTAssertTrue(helper.contains("try HostLoad.live.checkNotTimedOut(run.drainTimedOut, bound: Self.drainCap,"), helper)

        let reads = ["run.stderr", "run.terminationStatus", "run.untilMatchedAfter"]
        for name in ["testSpawnHelperCapturesChildThatWritesAfterOneSecond", "testSpawnHelperReturnsOnceUntilPredicateMatches",
                     "testBannerIsEmittedExactlyOnceAfterTheReexec", "testBannerSuppressedByEnvironmentVariable",
                     "testNoBannerForVersionFlag", "testNoBannerForHelpFlag", "testBannerHandlesArbitraryBinaryPath"] {
            assertFirst("try checkSpawnBounds(run", before: reads, in: try body("func \(name)() throws {", in: source), name)
        }
        let until = try body("func testSpawnHelperReturnsOnceUntilPredicateMatches() throws {", in: source)
        assertFirst("try HostLoad.live.checkWithinBound(elapsed, bound: 5.0,", before: reads, in: until, "until")

        // The cap test reads nothing the child wrote: that the cap fired is asserted first (hard),
        // the drain and the duration after it.
        let cap = try body("func testSpawnHelperReportsTimeoutWhenChildOutlivesTheCap() throws {", in: source)
        assertFirst("XCTAssertTrue(run.timedOut", before: ["try checkSpawnBounds(", "try HostLoad.live."], in: cap, "cap")
        assertFirst("XCTAssertNil(run.untilMatchedAfter)", before: ["try checkSpawnBounds(", "try HostLoad.live."], in: cap, "cap")
        XCTAssertTrue(cap.contains("try checkSpawnBounds(run, exitsBySelf: false,"), "the capped child is not expected to exit")
        XCTAssertTrue(cap.contains("try HostLoad.live.checkWithinBound(elapsed, bound: 3.0,"), cap)

        // The arbitrary-path test keeps its explicit 10 s cap on the spawn itself.
        let arbitrary = try body("func testBannerHandlesArbitraryBinaryPath() throws {", in: source)
        XCTAssertTrue(try arguments("spawnAndCaptureStderr(binary: tempBinary", in: arbitrary).contains("maxWait: 10.0"),
                      "the explicit 10 s budget is kept")

        // The timed banner test keeps its #366 order, and judges the drain before reading stderr.
        let banner = try body("func testBannerAppearsInDefaultMCPServerMode() throws {", in: source)
        assertFirst("try checkSpawnBounds(run, exitsBySelf: false,",
                    before: ["XCTAssertTrue(\n            run.stderr.contains(\"[banner] che-ical-mcp\")", "run.untilMatchedAfter"],
                    in: banner, "banner")
        assertFirst("try checkSpawnBounds(warmUp, exitsBySelf: false,", before: ["warmUp.terminationStatus"], in: banner, "warm-up")
    }

    // MARK: - Other spawns

    func testTheSelfDisclaimRunsJudgeTheirCapAndDrainFirst() throws {
        let source = try testFile("SelfDisclaimBinaryTests.swift")
        XCTAssertTrue(source.contains("static let printTCCPathTimeout: TimeInterval = 15"), "the 15 s bound is unchanged")
        XCTAssertTrue(source.contains("static let drainCap: TimeInterval = 5"), "the 5 s drain cap is unchanged")
        XCTAssertTrue(source.contains("let drainTimedOut = drained.wait(timeout: .now() + Self.drainCap) == .timedOut"))
        XCTAssertTrue(try arguments("return Run(", in: source).contains("drainTimedOut: drainTimedOut,"), "the drain reaches the result")
        XCTAssertFalse(source.contains("XCTAssertLessThan(run.elapsed"))
        let helper = try body("private func checkRunBounds(", in: source)
        XCTAssertTrue(helper.contains("try HostLoad.live.checkNotTimedOut(run.timedOut, bound: Self.printTCCPathTimeout,"), helper)
        XCTAssertTrue(helper.contains("try HostLoad.live.checkNotTimedOut(run.drainTimedOut, bound: Self.drainCap,"), helper)
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
        assertFirst("XCTAssertTrue(run.timedOut)", before: ["try HostLoad.live."], in: hang, "hang")
        XCTAssertTrue(hang.contains("try HostLoad.live.checkWithinBound(run.elapsed, bound: 10,"), hang)
    }

    func testThePrintTCCPathThroughPATHRunJudgesBeforeReading() throws {
        let test = try body("func testBareArgv0ThroughPATH_namesTheBinaryTheKernelRan_notAFileInTheCurrentDirectory() throws {",
                            in: try testFile("PrintTCCPathBinaryTests.swift"))
        XCTAssertTrue(test.contains("let timedOut = exited.wait(timeout: .now() + 20) == .timedOut"), test)
        XCTAssertTrue(test.contains("let drainTimedOut = drained.wait(timeout: .now() + 3) == .timedOut"), test)
        let stop = "guard !timedOut, !drainTimedOut else { return }"
        assertFirst("try HostLoad.live.checkNotTimedOut(timedOut, bound: 20,", before: [stop], in: test, "cap")
        assertFirst("try HostLoad.live.checkNotTimedOut(drainTimedOut, bound: 3,", before: [stop], in: test, "drain")
        // A regression is recorded without throwing, so the test stops before it reads `output`.
        assertFirst(stop, before: ["String(decoding: output"], in: test, "stop")
        let beforeStop = try XCTUnwrap(test.components(separatedBy: stop).first)
        XCTAssertFalse(beforeStop.contains("XCTFail("), "a timeout reported outside HostLoad")
    }

    func testTheStdioDrainSpawnsJudgeTheirCapAndDrainFirst() throws {
        let source = try testFile("StdioEOFDrainTests.swift")
        XCTAssertTrue(source.contains("maxWait: TimeInterval = 20) throws -> Run {"), "the 20 s cap is unchanged")
        XCTAssertTrue(source.contains("static let drainCap: TimeInterval = 3"), "the 3 s drain cap is unchanged")
        XCTAssertFalse(source.contains("XCTAssertTrue(run.exitedBySelf"))
        XCTAssertFalse(source.contains("XCTAssertLessThan(run.seconds"))
        let result = try arguments("return Run(", in: source)
        XCTAssertTrue(result.contains("exitedBySelf: exitedBySelf,"), result)
        XCTAssertTrue(result.contains("maxWait: maxWait, drainTimedOut: stdoutDrainTimedOut || stderrDrainTimedOut"), result)
        let helper = try body("private func checkRunBounds(", in: source)
        XCTAssertTrue(helper.contains("try HostLoad.live.checkNotTimedOut(!run.exitedBySelf, bound: run.maxWait,"), helper)
        XCTAssertTrue(helper.contains("try HostLoad.live.checkNotTimedOut(run.drainTimedOut, bound: Self.drainCap,"), helper)
        for name in ["testARequestReadBeforeEOFIsAnswered", "testEveryRequestReadBeforeEOFIsAnswered",
                     "testALargeIntegerIdReadBeforeEOFIsAnswered", "testABatchReadBeforeEOFIsAnswered",
                     "testWithNoRequestEOFStillEndsTheServer"] {
            assertFirst("try checkRunBounds(run", before: ["run.stdoutLines", "run.terminationStatus"],
                        in: try body("func \(name)() throws {", in: source), name)
        }
        let idle = try body("func testWithNoRequestEOFStillEndsTheServer() throws {", in: source)
        XCTAssertTrue(idle.contains("try HostLoad.live.checkWithinBound(run.seconds, bound: 10,"), idle)
    }

    // MARK: - In-process bounds

    func testTheInProcessBoundsGoThroughTheHelperAfterTheirAssertions() throws {
        // Pure function / returned result: complete either way, so they are asserted before the
        // skippable check.
        let tags = try body("func testAdversarialLineIsReturnedUnchanged() throws {", in: try testFile("ReminderTagsTests.swift"))
        XCTAssertTrue(tags.contains("try HostLoad.live.checkWithinBound(elapsed, bound: 1,"), tags)
        XCTAssertFalse(tags.contains("XCTAssertLessThan("), tags)
        for assertion in ["XCTAssertEqual(result.cleanNotes, input)", "XCTAssertTrue(result.tags.isEmpty)"] {
            assertFirst(assertion, before: ["try HostLoad.live."], in: tags, "tags")
        }

        let chain = try body("func testTimeout_reportsTimedOutAndEndsTheChild() throws {", in: try testFile("LiveParentChainSourceTests.swift"))
        XCTAssertTrue(chain.contains("try HostLoad.live.checkWithinBound(elapsed, bound: 10,"), chain)
        XCTAssertFalse(chain.contains("XCTAssertLessThan("), chain)
        for assertion in ["XCTAssertTrue(result.hops.isEmpty)", "XCTAssertEqual(result.failureReason"] {
            assertFirst(assertion, before: ["try HostLoad.live."], in: chain, "chain")
        }

        let latency = try testFile("TCCDriftBannerLatencyTests.swift")
        XCTAssertTrue(latency.contains("private let latencyTarget: Duration = .milliseconds(200)"), "the #127 target is unchanged")
        let median = try body("func testBannerBuildMedianIsUnderTheTarget() throws {", in: latency)
        XCTAssertTrue(median.contains("try HostLoad.live.checkWithinBound(Self.seconds(median), bound: Self.seconds(latencyTarget),"), median)
        XCTAssertFalse(median.contains("XCTAssertLessThan("), median)
    }

    func testTheTransportTestsJudgeTheirBoundsAfterCleanupIsRegistered() throws {
        let transport = try testFile("DrainingStdioTransportTests.swift")
        XCTAssertFalse(transport.contains("XCTAssertLessThan(elapsed, .seconds(5)") || transport.contains("XCTAssertLessThan(clock.now - start"),
                       "an upper time bound outside HostLoad")
        XCTAssertEqual(transport.components(separatedBy: "try checkUnder5Seconds(").count - 1, 5)
        let under = try body("private func checkUnder5Seconds(", in: transport)
        XCTAssertTrue(under.contains("try HostLoad.live.checkWithinBound(seconds, bound: 5,"), under)
        let waitUntil = try body("private func waitUntil(", in: transport)
        XCTAssertTrue(waitUntil.contains("for _ in 0..<500 {"), "the 500-poll bound is unchanged")
        XCTAssertTrue(waitUntil.contains("try await Task.sleep(for: .milliseconds(10))"), waitUntil)
        XCTAssertTrue(waitUntil.contains("try HostLoad.live.checkNotTimedOut(true, bound: 5,"), waitUntil)
        // A skip ends the test at the check, so the pipes' cleanup is a teardown block registered
        // when they are made, not code after the check.
        let make = try body("private func makeTransport(", in: transport)
        XCTAssertTrue(make.contains("addTeardownBlock {\n            close(serverRead)\n            await transport.disconnect()\n        }"), make)
        XCTAssertFalse(transport.contains("close(p.serverRead)"), "cleanup after a skippable check")
        XCTAssertFalse(transport.contains("await p.transport.disconnect()"), "cleanup after a skippable check")
    }

    // MARK: - Exceptions

    func testTheBudgetsHandedToProductionCodeAreNamedExceptions() throws {
        for (file, declaration) in [("LiveProcessInventorySourceTests.swift", "static let generousTimeoutMilliseconds = 10_000"),
                                    ("LiveTCCDatabaseSourceTests.swift", "static let generousTimeoutMilliseconds = 10_000"),
                                    ("LiveParentChainSourceTests.swift", "private let generousTimeoutMilliseconds = 10_000")] {
            let tests = try SourceScan.sourcesDirectory().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Tests/CheICalMCPTests")
            let raw = try String(contentsOf: tests.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(raw.contains(declaration), "\(file): the 10 s budget is unchanged")
            // The exception is documentation, so this one reads the comments.
            let comment = try XCTUnwrap(raw.components(separatedBy: declaration).first)
            XCTAssertTrue(comment.suffix(700).contains("A deliberate exception (#417)"), "\(file): the exception is named at the budget")
        }
    }
}
