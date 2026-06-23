import EventKit
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Runs the interactive `--setup` permission requests inside a foreground
/// `NSApplication` so EventKit's TCC dialogs can actually present.
///
/// **Why an NSApplication.** `requestFullAccessToEvents()` presents a system
/// modal that requires the requesting process to be a foreground app (regular
/// activation policy) with a running main run loop to pump the dialog. A bare
/// CLI async call (`await store.requestFullAccessToEvents()`) has neither, so on
/// macOS 14+/26 the *first* request silently returns `false` without ever
/// showing a dialog while a later request sometimes slips through — the
/// Calendar-denied / Reminders-granted asymmetry users hit (#163). che-apple-mail-mcp
/// solved the analogous Full Disk Access onboarding the same way
/// (`SetupWindow.run()` → `NSApplication.run()`, che-apple-mail-mcp#213); we mirror it here, minus
/// the SwiftUI window (EventKit has a request API, FDA does not — so we only need
/// the foreground app context, not an onboarding UI).
/// Outcome of evaluating one EventKit entity during `--setup`. A pure value so the
/// branch logic is unit-testable without an `EKEventStore` or stdout capture (#163).
enum SetupEntityOutcome: Equatable {
    case alreadyGranted
    case granted
    case denied
    case skippedWouldBlock
    case writeOnly
    /// Framework error during the request; payload is already stderr-sanitized.
    case error(String)

    /// Whether this outcome means setup did not fully succeed — the caller exits
    /// non-zero and prints manual-grant guidance.
    var isBad: Bool {
        switch self {
        case .alreadyGranted, .granted:
            return false
        case .denied, .skippedWouldBlock, .writeOnly, .error:
            return true
        }
    }

    /// The status line printed for this entity (e.g. `label == "Calendar"`).
    func message(label: String) -> String {
        switch self {
        case .alreadyGranted:
            return "\(label) access: ✓ already granted"
        case .granted:
            return "\(label) access: ✓ granted"
        case .denied:
            return "\(label) access: ✗ denied"
        case .skippedWouldBlock:
            return "\(label) access: ⤼ skipped — non-interactive session; requestFullAccess would block on a TCC dialog that can't appear here (#143). Grant manually (see below)."
        case .writeOnly:
            return "\(label) access: ◐ write-only (partial — upgrade to full access in System Settings)"
        case .error(let safeMessage):
            return "\(label) access: ✗ error — \(safeMessage)"
        }
    }
}

enum SetupRunner {
    /// Map one entity's authorization `status` (and, when the decision is
    /// `.requestAccess`, the injected `request` result) into a `SetupEntityOutcome`.
    /// The `request` closure is injected so tests can drive every branch
    /// (granted / denied / throwing) without an `EKEventStore` or a real TCC round-trip.
    /// Framework error text is escaped at the boundary (#146): control chars in
    /// `localizedDescription` must not pass raw to a terminal.
    static func evaluateEntity(
        status: EKAuthorizationStatus,
        nonInteractive: Bool,
        request: () async throws -> Bool
    ) async -> SetupEntityOutcome {
        switch setupAccessDecision(status: status, isNonInteractive: nonInteractive) {
        case .alreadyGranted:
            return .alreadyGranted
        case .requestAccess:
            do {
                return try await request() ? .granted : .denied
            } catch {
                return .error(EventKitErrorSanitizer.escapeForStderr(error.localizedDescription))
            }
        case .skipWouldBlock:
            return .skippedWouldBlock
        case .denied:
            return .denied
        case .writeOnly:
            return .writeOnly
        }
    }

    /// Request Calendar then Reminders full access, reusing the pure
    /// `setupAccessDecision` switch via ``evaluateEntity(status:nonInteractive:request:)``.
    /// Returns `true` if any entity was denied / blocked / write-only / errored
    /// (caller exits non-zero + prints guidance). Must run on the main actor; for
    /// `.requestAccess` the dialogs only present when a run loop is pumping (see
    /// ``runInteractive()``).
    @MainActor
    static func requestBoth(nonInteractive: Bool) async -> Bool {
        let store = EKEventStore()
        var anyBad = false

        func run(_ label: String, entity: EKEntityType,
                 request: () async throws -> Bool) async {
            let status = EKEventStore.authorizationStatus(for: entity)
            let outcome = await evaluateEntity(status: status, nonInteractive: nonInteractive, request: request)
            print(outcome.message(label: label))
            if outcome.isBad { anyBad = true }
        }

        await run("Calendar", entity: .event) { try await store.requestFullAccessToEvents() }
        await run("Reminders", entity: .reminder) { try await store.requestFullAccessToReminders() }
        return anyBad
    }

    /// Print the manual-grant guidance when any request was denied or skipped.
    static func printGuidanceIfNeeded(_ bad: Bool) {
        guard bad else { return }
        print("\nIf permissions were denied or skipped, grant them manually:")
        print("  System Settings → Privacy & Security → Calendar → enable CheICalMCP")
        print("  System Settings → Privacy & Security → Reminders → enable CheICalMCP")
    }

    /// Interactive path: present the SwiftUI `SetupWindow` inside a foreground
    /// `NSApplication` (#164) so the user sees live status + Grant buttons + the
    /// authorization-target binary path, and the TCC dialogs can present. Never returns.
    /// The window-driving lives in `SetupWindow`; non-AppKit/SwiftUI platforms degrade
    /// to the headless `requestBoth` flow there.
    @MainActor
    static func runInteractive() -> Never {
        SetupWindow.run()
    }
}
