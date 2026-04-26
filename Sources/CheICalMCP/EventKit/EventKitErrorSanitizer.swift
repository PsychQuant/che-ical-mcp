import EventKit
import Foundation

/// Maps a Swift `Error` to a stable string code that is safe to embed in MCP
/// responses. Designed for the `failures[].error` field of batch EventKit
/// operations where Apple-produced `localizedDescription` strings could (now or
/// in a future macOS) interpolate user-controlled reminder/event content.
///
/// The sanitizer reads only `NSError.domain` and `NSError.code` — never
/// `userInfo`, `localizedDescription`, or any other field that could carry
/// human-readable text. The full `localizedDescription` is returned alongside
/// the sanitized code as `rawLog` so the caller can write it to stderr (or
/// another trusted channel) without forwarding it to the client.
///
/// Callers MUST forward `rawLog` to a trusted channel (typically stderr) when
/// they would otherwise have used `error.localizedDescription` for debugging
/// — dropping `rawLog` silently degrades operator visibility. Conversely, the
/// `code` is the only field safe to embed in client-visible responses.

/// Marker protocol that opts a Swift `Error` type into pass-through dispatch
/// by `EventKitErrorSanitizer.sanitizeForResponse(_:)` — the type's author
/// asserts that `errorDescription` (or `localizedDescription`) is hand-written
/// and safe to forward verbatim to MCP clients without sanitization.
///
/// Opt in only when the description is fully author-controlled. Do NOT make
/// Foundation types like `URLError` / `CocoaError` / `POSIXError` conform —
/// their messages come from Apple frameworks and may carry user-content.
/// Checking `is LocalizedError` would be too broad; this empty protocol is
/// the explicit opt-in used by `eventkit-error-sanitization` spec R5.
public protocol TrustedErrorMessage {}

enum EventKitErrorSanitizer {

    static func sanitize(_ error: Error) -> SanitizedError {
        let nsError = error as NSError
        let rawLog = nsError.localizedDescription
        // Spec R4 fixes the response value-domain regex to `[0-9]+`. NSError.code
        // is a signed Int and some Foundation domains carry negative values
        // historically; using the absolute value preserves a stable encoding
        // (operators can still recover the magnitude) while keeping the regex
        // an invariant of the sanitizer's output.
        let codeMagnitude = nsError.code.magnitude

        if nsError.domain == EKErrorDomain {
            return SanitizedError(code: "eventkit_error_\(codeMagnitude)", rawLog: rawLog)
        }

        if isSwiftBridged(error: error, nsError: nsError) {
            return SanitizedError(code: "error_unknown", rawLog: rawLog)
        }

        let slug = slugifyDomain(nsError.domain)
        return SanitizedError(code: "error_\(slug)_\(codeMagnitude)", rawLog: rawLog)
    }

    // Swift `Error` values bridged to `NSError` by the runtime carry a domain
    // synthesised from the Swift type name, i.e. `String(reflecting: type(of:))`
    // — a leak of source-code identifiers we don't want in client-visible
    // output. A "real" NSError (constructed via `NSError(domain:code:)`) has a
    // domain that does NOT match its dynamic Swift type, so this comparison
    // distinguishes the two cleanly without relying on prefix heuristics.
    private static func isSwiftBridged(error: Error, nsError: NSError) -> Bool {
        nsError.domain == String(reflecting: type(of: error))
    }

    private static func slugifyDomain(_ domain: String) -> String {
        let tail: String
        if let dot = domain.lastIndex(of: ".") {
            tail = String(domain[domain.index(after: dot)...])
        } else {
            tail = domain
        }

        var result = ""
        result.reserveCapacity(tail.count)
        for scalar in tail.unicodeScalars {
            let v = scalar.value
            if (0x61...0x7A).contains(v) {           // a-z
                result.unicodeScalars.append(scalar)
            } else if (0x41...0x5A).contains(v) {    // A-Z → lowercase
                result.unicodeScalars.append(Unicode.Scalar(v + 0x20)!)
            } else if (0x30...0x39).contains(v) {    // 0-9
                result.unicodeScalars.append(scalar)
            } else {
                result.append("_")
            }
        }
        return result
    }
}

struct SanitizedError: Sendable, Equatable {
    let code: String
    let rawLog: String
}

extension EventKitErrorSanitizer {

    /// Type-driven dispatch for non-cleanup callers (spec R6). For author-
    /// controlled errors marked `TrustedErrorMessage`, returns the original
    /// `localizedDescription` so operator-friendly authored messages survive.
    /// Otherwise delegates to `sanitize(_:)`, preserving #32's R1–R4
    /// invariants (regex value-domain) for framework-thrown errors.
    static func sanitizeForResponse(_ error: Error) -> SanitizedError {
        if error is TrustedErrorMessage {
            let text = error.localizedDescription
            return SanitizedError(code: text, rawLog: text)
        }
        return sanitize(error)
    }

    /// Combines `sanitizeForResponse` with operator stderr logging in one
    /// call (spec R7). The `handler` and `identifier` parameters tag the
    /// stderr line with context for operator debugging. Returns the
    /// sanitized `code` for the caller to embed into the MCP response.
    ///
    /// Control characters (`\n`, `\r`) in `handler` / `identifier` / `rawLog`
    /// are escaped to `\\n` / `\\r` before the stderr write to prevent log
    /// injection (#37 F2): batch handlers may receive user-supplied
    /// identifiers (event titles, IDs from MCP arguments), and a `\n` in any
    /// of these would forge fake stderr lines visible to the operator.
    static func writeFailureLog(
        handler: String,
        identifier: String,
        error: Error
    ) -> String {
        let sanitized = sanitizeForResponse(error)
        let safeHandler = escapeForStderr(handler)
        let safeIdentifier = escapeForStderr(identifier)
        let safeRawLog = escapeForStderr(sanitized.rawLog)
        FileHandle.standardError.write(
            Data("\(safeHandler)(\(safeIdentifier)) failed: \(safeRawLog)\n".utf8)
        )
        return sanitized.code
    }

    private static func escapeForStderr(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }
}
