import Foundation
import XCTest
@testable import CheICalMCP

/// Direct unit tests for `LiveProcessInventorySource` failure modes (#124) + the
/// exact-basename match contract (#125). Pre-fix, this source was only exercised
/// through the binary-spawn integration tests, leaving edge cases (missing ps, similar-
/// named binaries inflating PID list) uncovered in CI.
final class LiveProcessInventorySourceTests: XCTestCase {

    // MARK: - Missing binary

    func testEnumerateMissingPS_returnsFailureReason() {
        let source = LiveProcessInventorySource(psPath: "/nonexistent/ps")
        let result = source.enumerateCheICalMCPProcesses()
        XCTAssertTrue(result.processes.isEmpty)
        XCTAssertEqual(result.failureReason, "ps not at /nonexistent/ps")
    }

    // MARK: - Live invocation (no CheICalMCP processes likely running in test env)

    /// Run against the real `/bin/ps` with a substring guaranteed not to match any
    /// host process (UUID-based). Exercises the full spawn + read + parse pipeline
    /// without depending on test-host state.
    func testEnumerateWithUnmatchableName_returnsEmptyWithoutFailure() {
        let source = LiveProcessInventorySource(
            psPath: "/bin/ps",
            processName: "definitely-not-running-\(UUID().uuidString)"
        )
        let result = source.enumerateCheICalMCPProcesses()
        XCTAssertTrue(result.processes.isEmpty,
            "no real process should match a UUID-named binary — got \(result.processes.count)")
        XCTAssertNil(result.failureReason,
            "happy-path empty result must NOT surface failureReason — got: \(String(describing: result.failureReason))")
    }

    // MARK: - Tiny timeout (#126)

    func testEnumerateWithTinyTimeout_surfacesTimeoutOrCompletes() {
        let source = LiveProcessInventorySource(
            psPath: "/bin/ps",
            processName: "ignored",
            timeoutMilliseconds: 1
        )
        let result = source.enumerateCheICalMCPProcesses()
        XCTAssertTrue(result.processes.isEmpty)
        // Race: either timeout fired before ps emitted output, or ps was fast enough.
        // Both are acceptable outcomes — the contract is bounded blocking with explicit
        // failure surfacing, not deterministic timeout reporting.
        if let reason = result.failureReason {
            XCTAssertTrue(
                reason.contains("timed out") || reason.hasPrefix("ps exit"),
                "tiny-timeout reason should be timeout or exit failure — got: \(reason)"
            )
        }
        // failureReason == nil is also valid: ps completed in <1ms with no matches and
        // produced clean output — the timer fired but the read had already drained.
    }
}

/// Pure parser tests for `ProcessInventoryParser.parseRow` — exact-basename match (#125)
/// closing the substring-match false-positive class.
final class ProcessInventoryParserTests: XCTestCase {

    private let formatter: DateFormatter = LiveProcessInventorySource.lstartFormatter

    func testParseRow_exactBasenameMatch_succeeds() {
        let row = "12345 Mon May 11 22:36:52 2026 /Users/test/bin/CheICalMCP"
        let parsed = ProcessInventoryParser.parseRow(row, processName: "CheICalMCP", lstartFormatter: formatter)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.pid, 12345)
        XCTAssertEqual(parsed?.executablePath, "/Users/test/bin/CheICalMCP")
    }

    /// The pre-#125 substring match accepted `CheICalMCP-helper` because the binary
    /// path contains the substring "CheICalMCP". Exact-basename match rejects it.
    func testParseRow_similarNameSuffix_rejected_no_false_positive() {
        let row = "12345 Mon May 11 22:36:52 2026 /Applications/SomeOther.app/CheICalMCP-helper"
        let parsed = ProcessInventoryParser.parseRow(row, processName: "CheICalMCP", lstartFormatter: formatter)
        XCTAssertNil(parsed, "exact-basename match must reject CheICalMCP-helper — would have been false positive under substring match (#125)")
    }

    func testParseRow_legacyBakSuffix_rejected_no_false_positive() {
        let row = "67890 Mon May 11 22:36:52 2026 /tmp/CheICalMCPLegacy.bak"
        let parsed = ProcessInventoryParser.parseRow(row, processName: "CheICalMCP", lstartFormatter: formatter)
        XCTAssertNil(parsed, "exact-basename match must reject CheICalMCPLegacy.bak — substring match would have falsely included it")
    }

    func testParseRow_emptyComm_rejected() {
        // Pathological: 6 valid lstart tokens but no comm field. Pre-fix verify finding
        // F6 surfaced this; the dedicated guard remains in place after the exact-basename
        // refactor.
        let row = "12345 Mon May 11 22:36:52 2026 "
        let parsed = ProcessInventoryParser.parseRow(row, processName: "CheICalMCP", lstartFormatter: formatter)
        XCTAssertNil(parsed)
    }

    func testParseRow_basenameMatchInDeepPath_succeeds() {
        // Verifies the basename extraction handles arbitrarily deep paths.
        let row = "99999 Mon May 11 22:36:52 2026 /Users/test/Library/Application Support/Claude/Claude Extensions/local.mcpb.che-cheng.che-ical-mcp/server/CheICalMCP"
        let parsed = ProcessInventoryParser.parseRow(row, processName: "CheICalMCP", lstartFormatter: formatter)
        XCTAssertNotNil(parsed, "deep path with CheICalMCP as basename must still match (#125 happy path)")
        XCTAssertEqual(parsed?.pid, 99999)
    }
}
