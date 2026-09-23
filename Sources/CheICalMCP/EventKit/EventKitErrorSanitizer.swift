import CheMCPKit
import EventKit
import Foundation

/// This server's error sanitizer: `CheMCPKit.ErrorSanitizer` plus one EventKit rule.
///
/// The sanitizer core (control-character escaping and stripping, the `TrustedErrorMessage`
/// carve-out, the stderr length cap, domain slugging) lives in che-mcp-kit-swift, shared with
/// the other PsychQuant Swift MCP servers (#223). What stays here is the code for Apple's
/// EventKit errors: `EKErrorDomain` errors are reported as `eventkit_error_<N>` rather than the
/// package's generic `error_<domain>_<N>`, a response contract clients already depend on
/// (`eventkit-error-sanitization` spec R2).
///
/// **`TrustedErrorMessage` conformers in this module** (the protocol itself is the package's):
///   - `ToolError` (Server.swift)
///   - `EventKitError` (EventKit/EventKitManager.swift)
///   - `UnrecoverableUndoError` (EventKit/UndoManager.swift)
/// plus the package's own `CLIRunner.CLIError` and `ResponseFormattingError`. Adding a conformer
/// MUST update this list and `testTrustedErrorMessageConformerListIsCanonical` in
/// `Tests/CheICalMCPTests/EventKitErrorSanitizerTests.swift`; every conformance widens the
/// trust boundary.
enum EventKitErrorSanitizer {

    /// Per-line cap on `rawLog` written to stderr by `writeFailureLog` (#86).
    static let maxRawLogChars = ErrorSanitizer.maxRawLogChars

    /// `eventkit_error_<N>` for `EKErrorDomain`; everything else as the package sanitizes it.
    static func sanitize(_ error: Error) -> SanitizedError {
        let nsError = error as NSError
        if nsError.domain == EKErrorDomain {
            return SanitizedError(code: "eventkit_error_\(nsError.code.magnitude)",
                                  rawLog: nsError.localizedDescription)
        }
        return ErrorSanitizer.sanitize(error)
    }

    /// Trusted errors pass through verbatim (spec R6); every other error goes through `sanitize`.
    static func sanitizeForResponse(_ error: Error) -> SanitizedError {
        if error is TrustedErrorMessage {
            return ErrorSanitizer.sanitizeForResponse(error)
        }
        return sanitize(error)
    }

    /// Writes the escaped, length-capped raw log to stderr for untrusted errors (spec R7, #41, #86)
    /// and returns the response code. The stderr line depends only on `rawLog`, so the package
    /// writes it; the returned code is this server's (EventKit rule included).
    static func writeFailureLog(handler: String, identifier: String, error: Error) -> String {
        _ = ErrorSanitizer.writeFailureLog(handler: handler, identifier: identifier, error: error)
        return sanitizeForResponse(error).code
    }

    /// Strip C0 controls and DEL from a string interpolated into a response message (#73/#74).
    static func sanitizeForInterpolation(_ s: String) -> String {
        ErrorSanitizer.sanitizeForInterpolation(s)
    }

    /// Escape backslash, LF, CR, C0, DEL and C1 for stderr (#37 F2, #73, #150).
    static func escapeForStderr(_ s: String) -> String {
        ErrorSanitizer.escapeForStderr(s)
    }
}
