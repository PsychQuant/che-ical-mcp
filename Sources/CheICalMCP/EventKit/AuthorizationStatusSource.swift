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
/// the safety guarantee instead: the gate runs on the caller's actor (#482), so the source, and the
/// store it holds, is used on the `EventKitManager` actor. Before #482 this comment said the source
/// never crossed an actor boundary, which did not hold: `AuthorizationGate.ensureAccess` was a
/// nonisolated async function, and in Swift 5 mode (SE-0338) it ran on the generic executor, so the
/// status read and the request on the actor's own store ran off the actor. The one other caller,
/// `SetupModel.grant` (the `--setup` window, which owns its own store), passes `nil` and keeps its
/// earlier behavior.
protocol AuthorizationStatusSource {
    /// Read current TCC authorization status. Cheap (μs-scale, kernel-cache hit after first call).
    /// MUST NOT trigger TCC dialog — that's `requestFullAccess`'s job.
    func authorizationStatus(for entityType: EKEntityType) -> EKAuthorizationStatus

    /// Request full access (triggers TCC dialog if `.notDetermined`).
    /// Only called by `AuthorizationGate.ensureAccess` when status is `.notDetermined`, which hands
    /// it its own isolation (#482): a nonisolated async requirement would run off the caller's
    /// actor (SE-0338). `SetupModel.grant` passes `nil`.
    func requestFullAccess(for entityType: EKEntityType, isolation: isolated (any Actor)?) async throws -> Bool
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

    func requestFullAccess(for entityType: EKEntityType, isolation: isolated (any Actor)?) async throws -> Bool {
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
    ///   - isolation: #482: the gate runs on the caller's actor (SE-0420), as #476's undo restore
    ///     seams do. In Swift 5 mode (SE-0338) a nonisolated async function runs on the generic
    ///     executor, so the status read and the request on `EventKitManager`'s own store ran off
    ///     that actor while it could re-enter and do EventKit work. The callers in
    ///     `EventKitManager` pass nothing, so `#isolation` gives them the actor; `nil` passed by
    ///     hand brings the old behavior back.
    /// - Throws:
    ///   - `EventKitError.accessDenied` for `.denied` / `.restricted` / `.notDetermined`-then-denied
    ///   - `EventKitError.insufficientAccess` for `.writeOnly` (macOS 14+ partial-access state)
    ///   - `EventKitError.unknownAuthState` for unrecognized future enum cases
    static func ensureAccess(
        for entityType: EKEntityType,
        typeName: String,
        isSSH: Bool = false,
        isNonInteractive: Bool = false,
        probe: AuthorizationStatusSource,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        let status = probe.authorizationStatus(for: entityType)

        switch status {
        case .fullAccess:
            return
        case .writeOnly:
            throw EventKitError.insufficientAccess(type: typeName)
        case .denied, .restricted:
            // Status is already denied → requestFullAccess is skipped (it only fires on
            // `.notDetermined`). Flag `deniedByStatus` so the message layer knows a bare
            // `--setup` cannot re-prompt from here — the #154 dead-end signature (#158).
            throw EventKitError.accessDenied(
                type: typeName, isSSH: isSSH, isNonInteractive: isNonInteractive, deniedByStatus: true)
        case .notDetermined:
            // A non-interactive session (SSH / launchd / CI runner / no TTY) cannot display
            // the TCC permission dialog that `requestFullAccess` triggers. On some hosts
            // (GitHub Actions macos sandbox #131, or over SSH) the request blocks indefinitely
            // waiting for a dialog that can never appear, hanging the process. Fast-fail with
            // the same actionable error as `.denied` instead of hanging — the user must grant
            // access interactively first (`--setup` from a Terminal, not over SSH).
            if isSSH || isNonInteractive {
                throw EventKitError.accessDenied(type: typeName, isSSH: isSSH, isNonInteractive: isNonInteractive)
            }
            let granted = try await probe.requestFullAccess(for: entityType, isolation: isolation)
            if !granted {
                throw EventKitError.accessDenied(type: typeName, isSSH: isSSH, isNonInteractive: isNonInteractive)
            }
        @unknown default:
            throw EventKitError.unknownAuthState(type: typeName, statusValue: status.rawValue)
        }
    }
}
