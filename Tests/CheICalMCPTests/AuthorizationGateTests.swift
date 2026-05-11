import EventKit
import XCTest
@testable import CheICalMCP

/// Pure unit tests for `AuthorizationGate.ensureAccess(for:typeName:probe:)` — the per-call
/// TCC authorization gate that replaces the legacy `hasCalendarAccess` / `hasReminderAccess`
/// process-lifetime caches (#108 Phase 2).
///
/// Coverage: each `EKAuthorizationStatus` case + `@unknown default` branch + the
/// `.notDetermined → request → grant` and `.notDetermined → request → deny` paths.
///
/// Uses `MockAuthorizationStatusSource` to inject status values + count request calls,
/// so no real EventKit access is needed.
@available(macOS 14.0, *)
final class AuthorizationGateTests: XCTestCase {

    // MARK: - Mock

    /// Test double that records request-call count + returns programmable status / grant result.
    final class MockAuthorizationStatusSource: AuthorizationStatusSource, @unchecked Sendable {
        private let status: EKAuthorizationStatus
        private let requestResult: Bool
        private(set) var requestCallCount: Int = 0

        init(status: EKAuthorizationStatus, requestResult: Bool = true) {
            self.status = status
            self.requestResult = requestResult
        }

        func authorizationStatus(for: EKEntityType) -> EKAuthorizationStatus { status }

        func requestFullAccess(for: EKEntityType) async throws -> Bool {
            requestCallCount += 1
            return requestResult
        }
    }

    // MARK: - Happy path

    func testFullAccess_returnsImmediatelyWithoutRequest() async throws {
        let probe = MockAuthorizationStatusSource(status: .fullAccess)
        try await AuthorizationGate.ensureAccess(for: .event, typeName: "Calendar", probe: probe)
        XCTAssertEqual(probe.requestCallCount, 0, "fullAccess should short-circuit; request must not be called")
    }

    // MARK: - Denied / restricted

    func testDenied_throwsAccessDenied() async throws {
        let probe = MockAuthorizationStatusSource(status: .denied)
        do {
            try await AuthorizationGate.ensureAccess(for: .event, typeName: "Calendar", probe: probe)
            XCTFail("Expected EventKitError.accessDenied for .denied")
        } catch let error as EventKitError {
            guard case .accessDenied(let type, _, _) = error else {
                XCTFail("Expected .accessDenied, got \(error)")
                return
            }
            XCTAssertEqual(type, "Calendar")
        }
        XCTAssertEqual(probe.requestCallCount, 0, ".denied must NOT trigger request (would silent-fail)")
    }

    func testRestricted_throwsAccessDenied() async throws {
        let probe = MockAuthorizationStatusSource(status: .restricted)
        do {
            try await AuthorizationGate.ensureAccess(for: .event, typeName: "Calendar", probe: probe)
            XCTFail("Expected EventKitError.accessDenied for .restricted")
        } catch let error as EventKitError {
            guard case .accessDenied = error else {
                XCTFail("Expected .accessDenied, got \(error)")
                return
            }
        }
        XCTAssertEqual(probe.requestCallCount, 0, ".restricted must NOT trigger request")
    }

    // MARK: - WriteOnly (partial access — macOS 14+)

    func testWriteOnly_throwsInsufficientAccess() async throws {
        let probe = MockAuthorizationStatusSource(status: .writeOnly)
        do {
            try await AuthorizationGate.ensureAccess(for: .event, typeName: "Calendar", probe: probe)
            XCTFail("Expected EventKitError.insufficientAccess for .writeOnly")
        } catch let error as EventKitError {
            guard case .insufficientAccess(let type) = error else {
                XCTFail("Expected .insufficientAccess, got \(error)")
                return
            }
            XCTAssertEqual(type, "Calendar")
        }
        XCTAssertEqual(probe.requestCallCount, 0, ".writeOnly must NOT trigger request (user must manually upgrade in System Settings)")
    }

    // MARK: - NotDetermined → request

    func testNotDetermined_grantedTriggersRequestAndReturns() async throws {
        let probe = MockAuthorizationStatusSource(status: .notDetermined, requestResult: true)
        try await AuthorizationGate.ensureAccess(for: .event, typeName: "Calendar", probe: probe)
        XCTAssertEqual(probe.requestCallCount, 1, ".notDetermined must trigger exactly one request")
    }

    func testNotDetermined_deniedTriggersRequestThenThrows() async throws {
        let probe = MockAuthorizationStatusSource(status: .notDetermined, requestResult: false)
        do {
            try await AuthorizationGate.ensureAccess(for: .event, typeName: "Calendar", probe: probe)
            XCTFail("Expected EventKitError.accessDenied after request returned false")
        } catch let error as EventKitError {
            guard case .accessDenied = error else {
                XCTFail("Expected .accessDenied, got \(error)")
                return
            }
        }
        XCTAssertEqual(probe.requestCallCount, 1, "request should still be attempted once before throwing")
    }

    // MARK: - typeName threaded into error

    func testReminderTypeName_propagatesIntoAccessDeniedError() async throws {
        let probe = MockAuthorizationStatusSource(status: .denied)
        do {
            try await AuthorizationGate.ensureAccess(for: .reminder, typeName: "Reminders", probe: probe)
            XCTFail("Expected EventKitError.accessDenied for .denied")
        } catch let error as EventKitError {
            guard case .accessDenied(let type, _, _) = error else {
                XCTFail("Expected .accessDenied, got \(error)")
                return
            }
            XCTAssertEqual(type, "Reminders", "typeName must be threaded through to error message")
        }
    }
}
