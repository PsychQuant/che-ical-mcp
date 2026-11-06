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

    /// The body of the function whose declaration starts with `declaration`, with its whitespace
    /// collapsed: from the first `{` after the declaration to its matching `}`. (`body(_:in:)`
    /// takes a marker that ends in `{`; a helper's signature spans lines, so it is found first.)
    private func helperBody(_ declaration: String, in source: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let start = try XCTUnwrap(source.range(of: declaration), declaration, file: file, line: line)
        let rest = String(source[start.lowerBound...])
        return SourceScan.collapsingWhitespace(try XCTUnwrap(SourceScan.body(of: "{", in: rest), declaration, file: file, line: line))
    }

    /// Every `XCTAssertLessThan…` in `source` (comments and string text removed, whitespace
    /// collapsed, so a multi-line call is seen) starts one of `allowed`, and there are exactly as
    /// many as `allowed` lists: an upper time bound outside `HostLoad` cannot come back, however it
    /// is written (PR #422 verify round 2).
    private func assertOnlyAllowedLessThan(in source: String, allowed: [String], _ name: String,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let code = SourceScan.collapsingWhitespace(SourceScan.codeOnly(source))
        var found: [String] = []
        var searchFrom = code.startIndex
        while let use = code.range(of: "XCTAssertLessThan", range: searchFrom..<code.endIndex) {
            let call = String(code[use.lowerBound...].prefix(80))
            found.append(call)
            XCTAssertTrue(allowed.contains { call.hasPrefix($0) }, "\(name): an upper bound outside HostLoad: \(call)", file: file, line: line)
            searchFrom = use.upperBound
        }
        XCTAssertEqual(found.count, allowed.count, "\(name): \(found)", file: file, line: line)
    }

    /// The number of `maxWait:` labels in `source`'s code (comments and string text removed).
    private func maxWaitCount(_ source: String) -> Int {
        SourceScan.codeOnly(source).components(separatedBy: "maxWait:").count - 1
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
        assertOnlyAllowedLessThan(in: source, allowed: ["XCTAssertLessThan(setupEnd, bannerCall,",
                                                        "XCTAssertLessThanOrEqual(matchedAfter, elapsed)"], "banner")
        // Every `maxWait:` in the file is a known one: the field, the default, the result's
        // forward, the cap test's 0.3 and the arbitrary-path test's 10.0; no call site loosens
        // the cap (PR #422 verify round 2).
        XCTAssertEqual(maxWaitCount(source), 5, "a new `maxWait:` in TCCDriftDetectorBannerTests")
        XCTAssertTrue(source.contains("static let drainCap: TimeInterval = 1.0"), "the 1 s drain cap is unchanged")

        // The cap: the spawn helper's own default, and the result carries the cap it ran with.
        let spawn = try arguments("func spawnAndCaptureStderr(", in: source)
        XCTAssertTrue(spawn.contains("maxWait: TimeInterval = 10.0,"), "the 10 s spawn cap is unchanged")
        let spawnBody = try helperBody("private func spawnAndCaptureStderr(", in: source)
        XCTAssertTrue(spawnBody.contains("let stderrDrainTimedOut = drainDone.wait(timeout: .now() + Self.drainCap) == .timedOut"))
        XCTAssertTrue(spawnBody.contains("let stdoutDrainTimedOut = stdoutDrainDone.wait(timeout: .now() + Self.drainCap) == .timedOut"))
        XCTAssertTrue(spawnBody.contains("maxWait: maxWait,"), "the result reports the cap the spawn used")
        XCTAssertTrue(spawnBody.contains("drainTimedOut: stderrDrainTimedOut || stdoutDrainTimedOut"), "both drains reach the result")

        // The check: no cap of its own; it reads the run's, and nothing else is in it.
        XCTAssertFalse(try arguments("private func checkSpawnBounds(", in: source).contains("maxWait"))
        XCTAssertEqual(try helperBody("private func checkSpawnBounds(", in: source),
                       #"if exitsBySelf { try HostLoad.live.checkNotTimedOut(run.timedOut, bound: run.maxWait, what, file: file, line: line) } try HostLoad.live.checkNotTimedOut(run.drainTimedOut, bound: Self.drainCap, "\(what): output drain", file: file, line: line)"#)

        let reads = ["run.stderr", "run.terminationStatus", "run.untilMatchedAfter"]
        for name in ["testSpawnHelperCapturesChildThatWritesAfterOneSecond", "testSpawnHelperReturnsOnceUntilPredicateMatches",
                     "testBannerIsEmittedExactlyOnceAfterTheReexec", "testBannerSuppressedByEnvironmentVariable",
                     "testNoBannerForVersionFlag", "testNoBannerForHelpFlag", "testBannerHandlesArbitraryBinaryPath"] {
            let test = try body("func \(name)() throws {", in: source)
            assertFirst("try checkSpawnBounds(run", before: reads, in: test, name)
            XCTAssertFalse(test.contains("exitsBySelf:"), "\(name): the child must still be checked for exiting by itself")
        }
        // Once the cap and the drain pass, the output is complete: it is asserted on before the
        // duration check, which a skip would otherwise keep from running.
        let until = try body("func testSpawnHelperReturnsOnceUntilPredicateMatches() throws {", in: source)
        for read in ["run.stderr", "run.untilMatchedAfter", "XCTAssertLessThanOrEqual(matchedAfter, elapsed)"] {
            assertFirst(read, before: ["try HostLoad.live.checkWithinBound(elapsed, bound: 5.0,"], in: until, "until")
        }

        // The cap test reads nothing the child wrote: that the cap fired is asserted first (hard),
        // the drain and the duration after it.
        let cap = try body("func testSpawnHelperReportsTimeoutWhenChildOutlivesTheCap() throws {", in: source)
        assertFirst("XCTAssertTrue(run.timedOut", before: ["try checkSpawnBounds(", "try HostLoad.live."], in: cap, "cap")
        assertFirst("XCTAssertNil(run.untilMatchedAfter)", before: ["try checkSpawnBounds(", "try HostLoad.live."], in: cap, "cap")
        XCTAssertTrue(cap.contains("try checkSpawnBounds(run, exitsBySelf: false,"), "the capped child is not expected to exit")
        XCTAssertEqual(SourceScan.collapsingWhitespace(try arguments("spawnAndCaptureStderr(", in: cap)),
                       #"binary: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], maxWait: 0.3"#)
        XCTAssertTrue(cap.contains("try HostLoad.live.checkWithinBound(elapsed, bound: 3.0,"), cap)

        // The arbitrary-path test keeps its explicit 10 s cap on the spawn itself.
        let arbitrary = try body("func testBannerHandlesArbitraryBinaryPath() throws {", in: source)
        XCTAssertEqual(SourceScan.collapsingWhitespace(try arguments("spawnAndCaptureStderr(", in: arbitrary)),
                       "binary: tempBinary, maxWait: 10.0", "the explicit 10 s budget is kept")

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
        XCTAssertEqual(try helperBody("private func checkRunBounds(", in: source),
                       #"try HostLoad.live.checkNotTimedOut(run.timedOut, bound: Self.printTCCPathTimeout, what, file: file, line: line) try HostLoad.live.checkNotTimedOut(run.drainTimedOut, bound: Self.drainCap, "\(what): output drain", file: file, line: line)"#)
        assertOnlyAllowedLessThan(in: source, allowed: [], "SelfDisclaim")
        XCTAssertEqual(source.components(separatedBy: "try checkRunBounds(").count - 1, 11)
        for name in ["testForcedDisclaim_reexecsAsItsOwnResponsibleProcessKeepingThePid", "testForcedDisclaim_saysSoOnStderr",
                     "testOptOut_keepsTheHostAsTheResponsibleProcess", "testSentinelAlreadySet_doesNotReexecAgain_andSaysItHadNoEffect",
                     "testPrintTCCPath_singleQuotesItsCommands", "testAnIneffectiveDisclaimStillShowsTheRecord",
                     "testAnInheritedValueIsNotPrinted", "testAClosedOrReaderlessStderrDoesNotStopTheReexec",
                     "testDuplicateSentinelEntriesDoNotDefeatTheLoopGuard"] {
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
        assertOnlyAllowedLessThan(in: test, allowed: [], "PATH test")
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
        XCTAssertEqual(try helperBody("private func checkRunBounds(", in: source),
                       #"try HostLoad.live.checkNotTimedOut(!run.exitedBySelf, bound: run.maxWait, "\(what) (the server should exit by itself on stdin EOF)", file: file, line: line) try HostLoad.live.checkNotTimedOut(run.drainTimedOut, bound: Self.drainCap, "\(what): output drain", file: file, line: line)"#)
        assertOnlyAllowedLessThan(in: source, allowed: [], "StdioEOFDrain")
        // The field, the 20 s default and the result's forward; no call passes its own cap.
        XCTAssertEqual(maxWaitCount(source), 3, "a new `maxWait:` in StdioEOFDrainTests")
        for name in ["testARequestReadBeforeEOFIsAnswered", "testEveryRequestReadBeforeEOFIsAnswered",
                     "testALargeIntegerIdReadBeforeEOFIsAnswered", "testABatchReadBeforeEOFIsAnswered",
                     "testWithNoRequestEOFStillEndsTheServer"] {
            assertFirst("try checkRunBounds(run", before: ["run.stdoutLines", "run.terminationStatus"],
                        in: try body("func \(name)() throws {", in: source), name)
        }
        let idle = try body("func testWithNoRequestEOFStillEndsTheServer() throws {", in: source)
        XCTAssertTrue(idle.contains("try HostLoad.live.checkWithinBound(run.seconds, bound: 10,"), idle)
        for read in ["XCTAssertEqual(run.terminationStatus, 0)", "run.stdoutLines"] {
            assertFirst(read, before: ["try HostLoad.live.checkWithinBound(run.seconds"], in: idle, "idle")
        }
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
        XCTAssertTrue(median.contains("try HostLoad.live.checkWithinBound(median, bound: latencyTarget,"), median)
        XCTAssertFalse(median.contains("XCTAssertLessThan("), median)
    }

    func testTheTransportTestsJudgeTheirBoundsAfterCleanupIsRegistered() throws {
        let transport = try testFile("DrainingStdioTransportTests.swift")
        XCTAssertFalse(transport.contains("XCTAssertLessThan(elapsed, .seconds(5)") || transport.contains("XCTAssertLessThan(clock.now - start"),
                       "an upper time bound outside HostLoad")
        XCTAssertEqual(transport.components(separatedBy: "try checkUnder5Seconds(").count - 1, 5)
        // The conversion lives in `HostLoad` and is tested there with injected values; the helper
        // is that one call (PR #422 verify round 2).
        XCTAssertEqual(try helperBody("private func checkUnder5Seconds(", in: transport),
                       "try HostLoad.live.checkWithinBound(elapsed, bound: .seconds(5), what, file: file, line: line)")
        assertOnlyAllowedLessThan(in: transport, allowed: [], "transport")
        let waitUntil = try helperBody("private func waitUntil(", in: transport)
        XCTAssertTrue(waitUntil.contains("for _ in 0..<500 {"), "the 500-poll bound is unchanged")
        XCTAssertTrue(waitUntil.contains("try await Task.sleep(for: .milliseconds(10))"), waitUntil)
        XCTAssertTrue(waitUntil.contains("try HostLoad.live.checkNotTimedOut(true, bound: 5,"), waitUntil)
        // A skip ends the test at the check, so the pipes' cleanup is a teardown block registered
        // when they are made, not code after the check; it closes all four ends.
        let teardown = SourceScan.collapsingWhitespace(try XCTUnwrap(SourceScan.body(of: "addTeardownBlock {", in: try helperBody("private func makeTransport(", in: transport))))
        XCTAssertEqual(teardown, "clientWrite.close() close(serverRead) await transport.disconnect() close(serverInput) close(serverOutput)")
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
