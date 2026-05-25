import EventKit
import XCTest
@testable import CheICalMCP

/// Validates that the `EventKitManager.forTesting(probe:)` DEBUG-only factory (#115) is
/// actually wired — without this test the factory ships as dead code, defeating the
/// purpose of the fileprivate init refactor (which exists so tests have a sanctioned
/// injection seam).
///
/// Surfaced as a verify finding in PR #135 (logic-reviewer MEDIUM-2, devils-advocate
/// HIGH escalation): the factory was defined but never called by any test. This test
/// closes that gap by exercising both ends of the seam — the factory accepts a custom
/// probe AND the resulting EventKitManager surfaces the probe's authorization decisions
/// through `ensureCalendarAccess` / `ensureReminderAccess`.
final class EventKitManagerForTestingTests: XCTestCase {

    /// Minimal stub probe — accepts a programmable authorization status, returns it on demand.
    /// Mirrors the AuthorizationGateTests Mock but stripped to the surface this test needs.
    private final class StubProbe: AuthorizationStatusSource {
        let status: EKAuthorizationStatus
        init(status: EKAuthorizationStatus) { self.status = status }
        func authorizationStatus(for: EKEntityType) -> EKAuthorizationStatus { status }
        func requestFullAccess(for: EKEntityType) async throws -> Bool { false }
    }

    /// Factory under test must produce an `EventKitManager` instance that routes
    /// authorization probes through the injected source (not the default Live one).
    /// We assert this end-to-end by injecting a `.denied` probe and confirming the
    /// resulting manager throws `EventKitError.accessDenied` from
    /// `ensureCalendarAccess()`.
    func testForTesting_injectsProbe_endToEnd_calendar() async throws {
        let probe = StubProbe(status: .denied)
        let manager = EventKitManager.forTesting(probe: probe)
        do {
            try await manager.ensureCalendarAccess()
            XCTFail("expected EventKitError.accessDenied to propagate from injected probe")
        } catch let error as EventKitError {
            guard case .accessDenied = error else {
                XCTFail("expected .accessDenied from injected probe, got \(error)")
                return
            }
        }
    }

    /// Symmetric test for the reminders path — `ensureReminderAccess` must also flow
    /// through the injected probe, not the production `EKEventStore` default.
    func testForTesting_injectsProbe_endToEnd_reminders() async throws {
        let probe = StubProbe(status: .denied)
        let manager = EventKitManager.forTesting(probe: probe)
        do {
            try await manager.ensureReminderAccess()
            XCTFail("expected EventKitError.accessDenied to propagate from injected probe")
        } catch let error as EventKitError {
            guard case .accessDenied = error else {
                XCTFail("expected .accessDenied from injected probe, got \(error)")
                return
            }
        }
    }

    /// Happy path: `.fullAccess` probe must let both gates return cleanly. Without this
    /// we could miss a regression where `forTesting` silently constructs a manager that
    /// always denies (regardless of probe).
    func testForTesting_injectsProbe_fullAccess_succeedsForBothEntities() async throws {
        let probe = StubProbe(status: .fullAccess)
        let manager = EventKitManager.forTesting(probe: probe)
        // Should not throw.
        try await manager.ensureCalendarAccess()
        try await manager.ensureReminderAccess()
    }
}
