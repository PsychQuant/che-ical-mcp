import Darwin  // pid_t
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Pure, injectable non-interactive-session detection (#149, #165).
///
/// Both the MCP-server access gate (`EventKitManager.isNonInteractiveSession`)
/// and the `--setup` manual path delegate here, so the predicate is unit-testable
/// over a full `(GUI session, CI, ppid) × includeCI` matrix instead of reading process
/// globals inline.
enum NonInteractiveDetection {
    /// A session is non-interactive (a TCC permission dialog cannot appear) when:
    /// - it is a direct launchd child (`ppid == 1`), OR
    /// - there is **no GUI (window-server / Aqua) session** (`!hasGUISession`), OR
    /// - (`includeCI` only) it is a CI runner (`CI` set).
    ///
    /// **Why `hasGUISession`, not `TERM == nil` (#165).** The previous form used
    /// `env["TERM"] == nil` as a proxy for "cannot show a dialog". That misfired for a
    /// process spawned by a GUI app (e.g. Claude Desktop spawning the MCP server): it has
    /// no controlling TTY (`TERM` unset) yet IS in the user's GUI session and CAN present a
    /// TCC dialog. The over-broad proxy made the gate fast-fail on `.notDetermined` without
    /// ever calling `requestFullAccess`, so the first-grant Calendar dialog never appeared
    /// through Claude Desktop. A window-server-session probe distinguishes "GUI-app-spawned,
    /// no TTY" (dialog CAN appear) from "truly headless: system launchd daemon / SSH without
    /// GUI" (dialog cannot).
    ///
    /// `includeCI` distinguishes the two call sites:
    /// - **`true`** — the MCP server gate: a CI runner can have a GUI session yet must not
    ///   block on `requestFullAccess`, so `.notDetermined` fast-fails there (#131).
    /// - **`false`** — `--setup`: a human-run manual path. A person in Terminal.app with
    ///   `CI=1` exported must still get the TCC dialog, so `CI` is deliberately excluded (#143).
    static func isNonInteractive(
        env: [String: String],
        ppid: pid_t,
        hasGUISession: Bool,
        includeCI: Bool
    ) -> Bool {
        ppid == 1
            || !hasGUISession
            || (includeCI && env["CI"] != nil)
    }

    /// Production GUI-session probe: `true` when the process is in a window-server (Aqua)
    /// session, so a TCC dialog can present — **even with no controlling TTY** (the case
    /// that matters for a GUI-app-spawned MCP server, e.g. Claude Desktop). A truly-headless
    /// context (system launchd daemon, SSH without GUI) has no such session and returns
    /// `false`. Cheap (a single CoreGraphics call); never prompts.
    static var hasGUISession: Bool {
        #if canImport(CoreGraphics)
        return CGSessionCopyCurrentDictionary() != nil
        #else
        return false
        #endif
    }
}
