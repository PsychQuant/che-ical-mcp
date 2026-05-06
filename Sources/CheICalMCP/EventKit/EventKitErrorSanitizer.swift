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
///
/// **Canonical conformer list** (CheICalMCP module):
///   - `ToolError` (Server.swift)
///   - `EventKitError` (EventKit/EventKitManager.swift)
///   - `CLIRunner.CLIError` (CLIRunner.swift)
///
/// Adding a new conformer MUST update both this list AND the test
/// `testTrustedErrorMessageConformerListIsCanonical` in
/// `Tests/CheICalMCPTests/EventKitErrorSanitizerTests.swift`. Any
/// conformance widens the trust boundary, so PR review SHOULD verify
/// every `errorDescription` of the new type is fully author-controlled
/// (no string interpolation of user/Apple-framework content).
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

    /// Per-line cap on `rawLog` written to stderr by `writeFailureLog`.
    /// Framework `NSError.localizedDescription` is theoretically unbounded;
    /// without a cap, batch handlers that fan out per malformed entry can
    /// amplify a single oversize Apple error into MB-scale stderr volume
    /// (#86 — DoS amplification residual closure). 1024 *characters* (Swift
    /// `String.count`, i.e. extended grapheme clusters — not UTF-8 bytes) is
    /// well above all Apple-emitted EKError descriptions observed empirically
    /// while still bounding the per-line cost. Pathological multi-byte
    /// graphemes (compound emoji etc.) can expand the post-escape byte count
    /// well beyond the cap; treat the bound as ~kilobytes per line, not exact
    /// byte budget. Internal so tests can pin the value. See #86 for tuning.
    static let maxRawLogChars = 1024

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
    ///
    /// **Trusted-branch carve-out (#41, spec R7 amendment)**: when `error`
    /// conforms to `TrustedErrorMessage`, the stderr write is skipped because
    /// `code == rawLog == localizedDescription` — the wire response already
    /// carries the same string and stderr would just duplicate. This avoids
    /// stderr amplification when an attacker sends N malformed batch entries
    /// (each a `ToolError.invalidParameter`) → N redundant stderr lines.
    /// Framework errors still write to stderr because they are the only
    /// operator-debuggable channel for the un-sanitized `localizedDescription`.
    ///
    /// **Length cap (#86)**: `rawLog` is truncated to `maxRawLogChars`
    /// characters before `escapeForStderr` (so escape inflation cannot
    /// expand the budget). Truncated lines carry a `…[truncated N chars]`
    /// suffix preserving the original size signal for operator debug.
    static func writeFailureLog(
        handler: String,
        identifier: String,
        error: Error
    ) -> String {
        let sanitized = sanitizeForResponse(error)
        if !(error is TrustedErrorMessage) {
            let safeHandler = escapeForStderr(handler)
            let safeIdentifier = escapeForStderr(identifier)
            // Cap fires BEFORE escapeForStderr so escape inflation
            // (`\n` → `\\n`, etc.) cannot expand the budget. Suffix
            // annotation tells operators the original payload size.
            let truncated: String
            if sanitized.rawLog.count > maxRawLogChars {
                let omitted = sanitized.rawLog.count - maxRawLogChars
                truncated = String(sanitized.rawLog.prefix(maxRawLogChars))
                    + "…[truncated \(omitted) chars]"
            } else {
                truncated = sanitized.rawLog
            }
            let safeRawLog = escapeForStderr(truncated)
            FileHandle.standardError.write(
                Data("\(safeHandler)(\(safeIdentifier)) failed: \(safeRawLog)\n".utf8)
            )
        }
        return sanitized.code
    }

    /// Escape control characters for safe stderr inclusion. Returns a
    /// version of `s` with: backslash → `\\`, LF → `\n`, CR → `\r`, and
    /// **all other C0 controls (`\x00..\x1F`) plus DEL (`\x7F`)** → `\xHH`
    /// hex escape. Other Unicode scalars (printable ASCII, accents, CJK,
    /// emoji) pass through unchanged.
    ///
    /// **Pre-#73 behavior** (3-char fast-path for backslash/LF/CR only) was
    /// a known gap: ESC `\x1b` reached stderr verbatim, allowing an
    /// attacker who controls `localizedDescription` (e.g. via event title
    /// surfaced in EKError text) to inject ANSI sequences like
    /// `\x1b[2J\x1b[H` (clear screen + home cursor) that hijack the
    /// operator's terminal — denial-of-visibility / log forgery class.
    /// `\x00` was a similar gap (truncates C-string log readers like
    /// `tail` writing to `syslog`). Closing both via full C0+DEL coverage.
    ///
    /// Promoted from `private` to `internal static` per #37 so callers that
    /// use `sanitize(_:)` directly (e.g. the `deleteRemindersBatch` catch
    /// path bound by spec R3) share the same control-char hardening.
    ///
    /// **C1 controls (`\x80..\x9F`)** are deferred — separate issue if
    /// terminal hijacking via the C1 alternate forms (e.g. `\xC2\x9B` ≡
    /// CSI) becomes an observed concern.
    static func escapeForStderr(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.unicodeScalars.count)
        for scalar in s.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x5C:   // backslash
                result.append("\\\\")
            case 0x0A:   // LF
                result.append("\\n")
            case 0x0D:   // CR
                result.append("\\r")
            case 0x00...0x1F, 0x7F:   // C0 + DEL
                result.append(String(format: "\\x%02x", v))
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
