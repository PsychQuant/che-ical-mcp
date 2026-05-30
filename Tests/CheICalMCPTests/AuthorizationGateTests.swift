import EventKit
import XCTest
@testable import CheICalMCP

/// Pure unit tests for `AuthorizationGate.ensureAccess(for:typeName:isSSH:isLaunchd:probe:)` —
/// the per-call TCC authorization gate that replaces the legacy `hasCalendarAccess` /
/// `hasReminderAccess` process-lifetime caches (#108 Phase 2).
///
/// Coverage: each `EKAuthorizationStatus` case + `@unknown default` branch + the
/// `.notDetermined → request → grant` and `.notDetermined → request → deny` paths,
/// plus the SSH/launchd context threading (#113) and unsupported-entity throw (#118).
///
/// Uses `MockAuthorizationStatusSource` to inject status values + count request calls,
/// so no real EventKit access is needed.
final class AuthorizationGateTests: XCTestCase {

    // MARK: - Mock

    /// Test double that records request-call count + returns programmable status / grant result
    /// (or throws when `requestError` is provided).
    ///
    /// **Single-test fresh-instance pattern only — never share across tests.** (#120)
    /// `requestCallCount` is mutated without synchronization; each test method constructs
    /// its own instance so cross-test sharing under `-parallel-testing-enabled` cannot race.
    /// If you find yourself reusing one mock across multiple test methods, wrap the counter
    /// in `OSAllocatedUnfairLock` or split into per-test instances instead.
    final class MockAuthorizationStatusSource: AuthorizationStatusSource {
        private let status: EKAuthorizationStatus
        private let requestResult: Bool
        private let requestError: Error?
        private(set) var requestCallCount: Int = 0

        init(status: EKAuthorizationStatus, requestResult: Bool = true, requestError: Error? = nil) {
            self.status = status
            self.requestResult = requestResult
            self.requestError = requestError
        }

        func authorizationStatus(for: EKEntityType) -> EKAuthorizationStatus { status }

        func requestFullAccess(for: EKEntityType) async throws -> Bool {
            requestCallCount += 1
            if let err = requestError { throw err }
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

    /// #131: in a non-interactive session (launchd / CI runner) the gate must NOT call
    /// `requestFullAccess` for `.notDetermined` — on a GHA CI sandbox that request blocks
    /// forever waiting for a TCC dialog that can never appear. Fast-fail instead of hanging.
    func testNotDetermined_inNonInteractiveSession_fastFailsWithoutRequest() async throws {
        let probe = MockAuthorizationStatusSource(status: .notDetermined)
        do {
            try await AuthorizationGate.ensureAccess(
                for: .event, typeName: "Calendar", isLaunchd: true, probe: probe
            )
            XCTFail("Expected .accessDenied for .notDetermined in a non-interactive session")
        } catch let error as EventKitError {
            guard case .accessDenied(let type, _, let isLaunchd) = error else {
                XCTFail("Expected .accessDenied, got \(error)")
                return
            }
            XCTAssertEqual(type, "Calendar")
            XCTAssertTrue(isLaunchd, "isLaunchd context should thread through the error")
        }
        XCTAssertEqual(
            probe.requestCallCount, 0,
            ".notDetermined + isLaunchd must NOT call requestFullAccess (would block on CI, #131)"
        )
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

    // MARK: - SSH / launchd context threading (#113)

    func testDenied_threadsIsSSHFlagIntoError() async throws {
        let probe = MockAuthorizationStatusSource(status: .denied)
        do {
            try await AuthorizationGate.ensureAccess(
                for: .event, typeName: "Calendar",
                isSSH: true, isLaunchd: false,
                probe: probe
            )
            XCTFail("Expected EventKitError.accessDenied")
        } catch let error as EventKitError {
            guard case .accessDenied(_, let isSSH, let isLaunchd) = error else {
                XCTFail("Expected .accessDenied, got \(error)")
                return
            }
            XCTAssertTrue(isSSH, "isSSH flag must be threaded into error so SSH-specific workaround text is surfaced (#108 regression fix #113)")
            XCTAssertFalse(isLaunchd, "isLaunchd must remain false when not supplied")
        }
    }

    func testDenied_threadsIsLaunchdFlagIntoError() async throws {
        let probe = MockAuthorizationStatusSource(status: .restricted)
        do {
            try await AuthorizationGate.ensureAccess(
                for: .event, typeName: "Calendar",
                isSSH: false, isLaunchd: true,
                probe: probe
            )
            XCTFail("Expected EventKitError.accessDenied")
        } catch let error as EventKitError {
            guard case .accessDenied(_, let isSSH, let isLaunchd) = error else {
                XCTFail("Expected .accessDenied, got \(error)")
                return
            }
            XCTAssertFalse(isSSH, "isSSH must remain false when not supplied")
            XCTAssertTrue(isLaunchd, "isLaunchd flag must be threaded into error so launchd-specific workaround text is surfaced (#113)")
        }
    }

    /// #131: `.notDetermined` in a non-interactive session (isSSH and/or isLaunchd) must
    /// fast-fail WITHOUT calling `requestFullAccess` — over SSH or on a CI runner the request
    /// blocks forever waiting for a TCC dialog that can never appear. The thrown error must
    /// still thread both context flags so #113's SSH/launchd workaround text surfaces.
    /// (Was `testNotDeterminedThenDenied_threadsContextFlagsIntoError`, which asserted a
    /// post-request denial; #131 moved the non-interactive case to a pre-request fast-fail.)
    func testNotDetermined_nonInteractive_fastFailsAndThreadsContextFlags() async throws {
        let probe = MockAuthorizationStatusSource(status: .notDetermined, requestResult: false)
        do {
            try await AuthorizationGate.ensureAccess(
                for: .reminder, typeName: "Reminders",
                isSSH: true, isLaunchd: true,
                probe: probe
            )
            XCTFail("Expected EventKitError.accessDenied (non-interactive fast-fail)")
        } catch let error as EventKitError {
            guard case .accessDenied(let type, let isSSH, let isLaunchd) = error else {
                XCTFail("Expected .accessDenied, got \(error)")
                return
            }
            XCTAssertEqual(type, "Reminders")
            XCTAssertTrue(isSSH, "fast-fail path must thread isSSH (#113)")
            XCTAssertTrue(isLaunchd, "fast-fail path must thread isLaunchd (#113)")
        }
        XCTAssertEqual(
            probe.requestCallCount, 0,
            "#131: non-interactive .notDetermined must NOT call requestFullAccess (would block on CI / SSH)"
        )
    }

    // MARK: - Unsupported entity (#118)

    func testUnsupportedEntityType_propagatesAsTypedError() async throws {
        // Simulate `requestFullAccess` throwing `unsupportedEntityType` when EKEntityType
        // hits the `@unknown default` arm. We can't construct a real `@unknown` case here
        // (Swift won't let us), so we model the throw via the mock's `requestError` channel
        // and assert the gate re-surfaces the typed error rather than wrapping it as denied.
        let probe = MockAuthorizationStatusSource(
            status: .notDetermined,
            requestError: EventKitError.unsupportedEntityType(rawValue: 99)
        )
        do {
            try await AuthorizationGate.ensureAccess(for: .event, typeName: "Calendar", probe: probe)
            XCTFail("Expected EventKitError.unsupportedEntityType to propagate")
        } catch let error as EventKitError {
            guard case .unsupportedEntityType(let raw) = error else {
                XCTFail("Expected .unsupportedEntityType, got \(error) — gate must NOT mask this as accessDenied (#118)")
                return
            }
            XCTAssertEqual(raw, 99)
        }
    }
}
