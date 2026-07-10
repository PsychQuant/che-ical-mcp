import XCTest
@testable import CheICalMCP

/// Behavior tests for `LiveParentChainSource`'s failure paths (#173, logic F3/F4).
/// The `psPath` init parameter accepts any executable, so each test points it at a
/// small fixture script — real subprocess behavior, no mocks.
final class LiveParentChainSourceTests: XCTestCase {

    private var fixtures: [URL] = []

    override func tearDown() {
        for url in fixtures { try? FileManager.default.removeItem(at: url) }
        fixtures = []
        super.tearDown()
    }

    /// Write an executable shell script and return its path.
    private func makeScript(_ body: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-ps-\(UUID().uuidString).sh")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        fixtures.append(url)
        return url.path
    }

    func testNonUTF8Output_reportsFailureReasonInsteadOfEmptyChain() throws {
        // printf emits an invalid UTF-8 byte sequence (lone 0xFF continuation bytes).
        let script = try makeScript(#"printf '  500   400 /bin/\377\377zsh\n'"#)
        let result = LiveParentChainSource(psPath: script).captureChain(from: 500)
        XCTAssertTrue(result.hops.isEmpty)
        XCTAssertEqual(result.failureReason, "ps output not UTF-8",
                       "silent empty-table success would misreport a decode failure as a clean run")
    }

    func testNonZeroExit_reportsStatusAndStderrFirstLine() throws {
        let script = try makeScript("echo 'ps: illegal option' >&2; exit 64")
        let result = LiveParentChainSource(psPath: script).captureChain(from: 500)
        XCTAssertTrue(result.hops.isEmpty)
        let reason = try XCTUnwrap(result.failureReason)
        XCTAssertTrue(reason.contains("64"), "exit status must be visible — got: \(reason)")
        XCTAssertTrue(reason.contains("ps: illegal option"),
                      "stderr first line is the actionable part of a ps failure — got: \(reason)")
    }

    func testHappyPath_stillWalksNormally() throws {
        let script = try makeScript("""
            printf '  500   400 /bin/zsh\\n'
            printf '  400     1 /sbin/launchd-ish\\n'
            printf '    1     0 /sbin/launchd\\n'
            """)
        let result = LiveParentChainSource(psPath: script).captureChain(from: 500)
        XCTAssertNil(result.failureReason)
        XCTAssertEqual(result.hops.map(\.pid), [500, 400, 1])
    }
}
