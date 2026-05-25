@preconcurrency import EventKit
import Foundation

/// Test seam for TCC authorization probing. Production wires `LiveAuthorizationStatusSource`;
/// tests inject a `MockAuthorizationStatusSource` (see `AuthorizationGateTests.swift`).
///
/// Per `CLAUDE.md` "Test Seam Convention" — `<Domain>Source` naming, narrow surface area
/// (2 methods), default-wired in `EventKitManager.init` so production callers are unaffected.
///
/// Why this exists (#108 Phase 2): the legacy `EventKitManager.requestCalendarAccess()` /
/// `requestReminderAccess()` methods cached the granted state in actor-private booleans
/// (`hasCalendarAccess` / `hasReminderAccess`) that were never re-checked. This violated
/// Apple's documented "call `authorizationStatus(for:)` each time" pattern (TN3153 +
/// `EKEventStore.authorizationStatus(for:)` API docs) and produced a silent-failure mode
/// where any future TCC state change (manual System Settings revoke / future macOS policy
/// shift / cross-Developer-ID re-signing) was invisible to the running process. The probe
/// + gate combination replaces the cache with a per-call cheap status check.
///
/// **Why no `Sendable` constraint** (#116): `LiveAuthorizationStatusSource` carries a
/// non-`Sendable` `EKEventStore`; declaring the protocol `Sendable` would force every
/// conformer into `@unchecked Sendable` (which papered over a real Swift 6 strict-
/// concurrency violation). Actor isolation in `EventKitManager` (the sole owner) provides
/// the safety guarantee instead — the source never crosses an actor boundary in production.
protocol AuthorizationStatusSource {
    /// Read current TCC authorization status. Cheap (μs-scale, kernel-cache hit after first call).
    /// MUST NOT trigger TCC dialog — that's `requestFullAccess`'s job.
    func authorizationStatus(for entityType: EKEntityType) -> EKAuthorizationStatus

    /// Request full access (triggers TCC dialog if `.notDetermined`).
    /// Only called by `AuthorizationGate.ensureAccess` when status is `.notDetermined`.
    func requestFullAccess(for entityType: EKEntityType) async throws -> Bool
}

/// Production implementation that delegates to the framework. Carries an `EKEventStore`
/// instance so the request originates from the same store EventKitManager uses for data ops
/// (avoids cross-store TCC attribution quirks).
struct LiveAuthorizationStatusSource: AuthorizationStatusSource {
    private let store: EKEventStore

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    func authorizationStatus(for entityType: EKEntityType) -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: entityType)
    }

    func requestFullAccess(for entityType: EKEntityType) async throws -> Bool {
        switch entityType {
        case .event:
            return try await store.requestFullAccessToEvents()
        case .reminder:
            return try await store.requestFullAccessToReminders()
        @unknown default:
            throw EventKitError.unsupportedEntityType(rawValue: entityType.rawValue)
        }
    }
}

/// Pure gate logic — checks current TCC status and dispatches to the correct outcome:
/// no-op (already granted), throw with actionable error (denied/restricted/writeOnly/unknown),
/// or trigger the TCC prompt (notDetermined → request → throw if denied after prompt).
///
/// **Why a free standing enum / static method**: lets tests exercise the full switch
/// without instantiating `EventKitManager` (which carries a real `EKEventStore`).
/// `EventKitManager.ensureCalendarAccess()` / `ensureReminderAccess()` are thin wrappers
/// over `AuthorizationGate.ensureAccess(...)`.
enum AuthorizationGate {
    /// Ensure TCC authorization is in `.fullAccess` state, or throw with an actionable error.
    ///
    /// - Parameters:
    ///   - entityType: EventKit entity (`.event` or `.reminder`)
    ///   - typeName: human-readable name for error messages ("Calendar" / "Reminders")
    ///   - probe: source of authorization-status reads + access requests
    /// - Throws:
    ///   - `EventKitError.accessDenied` for `.denied` / `.restricted` / `.notDetermined`-then-denied
    ///   - `EventKitError.insufficientAccess` for `.writeOnly` (macOS 14+ partial-access state)
    ///   - `EventKitError.unknownAuthState` for unrecognized future enum cases
    static func ensureAccess(
        for entityType: EKEntityType,
        typeName: String,
        isSSH: Bool = false,
        isLaunchd: Bool = false,
        probe: AuthorizationStatusSource
    ) async throws {
        let status = probe.authorizationStatus(for: entityType)

        switch status {
        case .fullAccess:
            return
        case .writeOnly:
            throw EventKitError.insufficientAccess(type: typeName)
        case .denied, .restricted:
            throw EventKitError.accessDenied(type: typeName, isSSH: isSSH, isLaunchd: isLaunchd)
        case .notDetermined:
            let granted = try await probe.requestFullAccess(for: entityType)
            if !granted {
                throw EventKitError.accessDenied(type: typeName, isSSH: isSSH, isLaunchd: isLaunchd)
            }
        @unknown default:
            throw EventKitError.unknownAuthState(type: typeName, statusValue: status.rawValue)
        }
    }
}
