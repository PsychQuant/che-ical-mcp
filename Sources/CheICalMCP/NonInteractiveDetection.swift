import Darwin  // pid_t
import Foundation

/// Pure, injectable non-interactive-session detection (#149).
///
/// Both the MCP-server access gate (`EventKitManager.isNonInteractiveSession`)
/// and the `--setup` manual path delegate here, so the predicate is unit-testable
/// over a full `(TERM, CI, ppid) × includeCI` matrix instead of reading process
/// globals inline (which left the `--setup` 2-clause form untested and the gate's
/// 3-clause form only mirror-tested — PR #148 verify).
enum NonInteractiveDetection {
    /// A session is non-interactive (a TCC permission dialog cannot appear) when:
    /// - it is a direct launchd child (`ppid == 1`), OR
    /// - there is no controlling TTY (`TERM` unset), OR
    /// - (`includeCI` only) it is a CI runner (`CI` set — no GUI).
    ///
    /// `includeCI` distinguishes the two call sites:
    /// - **`true`** — the MCP server gate: a CI runner genuinely has no GUI, so a
    ///   `.notDetermined` status must fast-fail rather than block on `requestFullAccess` (#131).
    /// - **`false`** — `--setup`: a human-run manual path. A person in Terminal.app with
    ///   `CI=1` exported must still get the TCC dialog, so `CI` is deliberately excluded (#143).
    static func isNonInteractive(
        env: [String: String],
        ppid: pid_t,
        includeCI: Bool
    ) -> Bool {
        ppid == 1
            || env["TERM"] == nil
            || (includeCI && env["CI"] != nil)
    }
}
