import XCTest
@testable import CheICalMCP

/// Coverage for `ParentChainFormatter.executionContextSection` (#169) — the display layer
/// of the `--print-tcc-path` execution-context block. Extracted from `main.swift` per the
/// #117 precedent (TCCStatusFormatter) so output shape is unit-testable without spawning
/// the binary. The context-dependence warning is the load-bearing line: it must survive
/// every variant (normal chain, capture failure), because it is what stops users from
/// reading a Terminal-context status as a Claude-Desktop verdict (#168).
final class ParentChainFormatterTests: XCTestCase {

    private let selfPath = "/Users/u/bin/CheICalMCP"

    func testNormalChain_rendersSelfMarkerAndAllHops() {
        let result = ParentChainResult(
            hops: [
                .init(pid: 400, command: "/bin/zsh"),
                .init(pid: 1, command: "/sbin/launchd"),
            ],
            failureReason: nil
        )
        let s = ParentChainFormatter.executionContextSection(selfPid: 500, selfPath: selfPath, result: result)
        XCTAssertTrue(s.contains("Execution context (parent process chain):"))
        XCTAssertTrue(s.contains("500  \(selfPath)  (this binary)"))
        XCTAssertTrue(s.contains("400  /bin/zsh"))
        XCTAssertTrue(s.contains("1  /sbin/launchd"))
    }

    func testFailure_rendersUnavailableReasonInsteadOfHops() {
        let result = ParentChainResult(hops: [], failureReason: "ps timed out after 500ms")
        let s = ParentChainFormatter.executionContextSection(selfPid: 500, selfPath: selfPath, result: result)
        XCTAssertTrue(s.contains("(parent chain unavailable: ps timed out after 500ms)"))
        XCTAssertTrue(s.contains("(this binary)"), "self line comes from local state, not ps — must render even when ps fails")
    }

    func testWarningLine_presentInBothVariants() {
        let ok = ParentChainFormatter.executionContextSection(
            selfPid: 500, selfPath: selfPath,
            result: ParentChainResult(hops: [.init(pid: 1, command: "/sbin/launchd")], failureReason: nil))
        let failed = ParentChainFormatter.executionContextSection(
            selfPid: 500, selfPath: selfPath,
            result: ParentChainResult(hops: [], failureReason: "ps not at /bin/ps"))
        for s in [ok, failed] {
            XCTAssertTrue(s.contains("NOTE: the authorization status above reflects the CURRENT execution context"))
            XCTAssertTrue(s.contains("run this command from within that host's environment"))
        }
    }

    func testEmptyChainWithoutFailure_stillRendersSelfAndWarning() {
        // ps succeeded but the table somehow lacked our ppid — degenerate but legal.
        let s = ParentChainFormatter.executionContextSection(
            selfPid: 500, selfPath: selfPath,
            result: ParentChainResult(hops: [], failureReason: nil))
        XCTAssertTrue(s.contains("(this binary)"))
        XCTAssertTrue(s.contains("NOTE: the authorization status above reflects the CURRENT execution context"))
    }
}
