import XCTest
@testable import CheICalMCP

/// Live coverage for `LiveResponsibleProcessSource` (#343). The kernel's responsibility
/// SPI is looked up at runtime, so these tests are the proof that the lookup resolves on
/// the host macOS and that a bogus pid degrades to a reason instead of a fake answer.
final class LiveResponsibleProcessSourceTests: XCTestCase {

    func testCurrentProcess_resolvesToAProcessWithAPath() {
        let result = LiveResponsibleProcessSource().responsibleProcess(for: getpid())
        guard case .resolved(let responsible) = result else {
            return XCTFail("expected the responsibility SPI to resolve for the test runner, got \(result)")
        }
        XCTAssertGreaterThan(responsible.pid, 0)
        XCTAssertNotNil(responsible.path, "proc_pidpath of a live responsible process must succeed")
    }

    func testNonexistentPid_isUnavailableWithReason() {
        let result = LiveResponsibleProcessSource().responsibleProcess(for: 999_999)
        guard case .unavailable(let reason) = result else {
            return XCTFail("a pid that does not exist must not resolve, got \(result)")
        }
        XCTAssertFalse(reason.isEmpty)
    }
}
