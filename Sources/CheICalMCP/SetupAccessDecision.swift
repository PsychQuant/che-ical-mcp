import EventKit

/// What `--setup` should do for one EventKit entity type, derived purely from the
/// current TCC authorization status + whether the session is non-interactive (#143).
///
/// Extracted as a pure function so the `--setup` decision is unit-testable without
/// spawning a real TCC dialog or blocking on `requestFullAccess`.
enum SetupAccessDecision: Equatable {
    /// `.fullAccess` — already granted; report success WITHOUT calling
    /// `requestFullAccess` (the already-granted re-run case must not hang or
    /// re-prompt).
    case alreadyGranted
    /// `.notDetermined` in an interactive session — call `requestFullAccess`
    /// so the macOS TCC permission dialog can appear.
    case requestAccess
    /// `.notDetermined` in a non-interactive session (SSH / launchd / CI / no TTY)
    /// — `requestFullAccess` would block forever on a dialog that can never
    /// appear, so skip it and surface manual remediation instead (#143). This is
    /// the same non-interactive fast-fail principle the AuthorizationGate applies
    /// to the MCP server path (#131); `--setup` previously only *warned* then
    /// called the blocking API anyway.
    case skipWouldBlock
    /// `.denied` / `.restricted` — report denied with remediation.
    case denied
    /// `.writeOnly` partial access (macOS 14+) — report partial.
    case writeOnly
}

/// Pure decision for the `--setup` flow. Mirrors `AuthorizationGate.ensureAccess`'s
/// status switch but returns an action instead of throwing, because `--setup`
/// reports status to the user rather than gating an operation.
func setupAccessDecision(
    status: EKAuthorizationStatus,
    isNonInteractive: Bool
) -> SetupAccessDecision {
    switch status {
    case .fullAccess:
        return .alreadyGranted
    case .writeOnly:
        return .writeOnly
    case .denied, .restricted:
        return .denied
    case .notDetermined:
        // The crux of #143: only skip when a dialog genuinely can't appear.
        // An already-granted status never reaches here (handled by .fullAccess),
        // so a non-interactive re-run of an already-authorized binary still
        // reports success rather than being skipped.
        return isNonInteractive ? .skipWouldBlock : .requestAccess
    @unknown default:
        return .denied
    }
}
