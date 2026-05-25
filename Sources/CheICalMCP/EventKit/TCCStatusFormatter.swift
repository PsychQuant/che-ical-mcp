import EventKit

/// Human-readable formatter for `EKAuthorizationStatus`, used by the `--print-tcc-path`
/// diagnostic output (and any future consumer that needs to surface TCC state to a user).
///
/// Extracted from `main.swift` (#117) so the formatting logic — including the
/// `@unknown default` raw-value escape hatch — is unit-testable without spawning
/// a binary and parsing stderr.
enum TCCStatusFormatter {
    /// Render a TCC authorization status as a single human-readable line, including
    /// the "why this matters" gloss. Always returns a non-empty string; future Apple
    /// enum additions surface as `unknown (raw value N)` rather than crashing.
    static func describe(_ status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined (never asked / TCC db has no entry)"
        case .restricted:
            return "restricted (system policy denies — Screen Time / MDM / etc.)"
        case .denied:
            return "denied (user explicitly denied)"
        case .fullAccess:
            return "fullAccess (granted)"
        case .writeOnly:
            return "writeOnly (partial — can create but not read)"
        @unknown default:
            return "unknown (raw value \(status.rawValue))"
        }
    }
}
