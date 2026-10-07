import XCTest

/// #242 (PR #277 verify round 1): the reminder undo arms reach the list only through
/// `ReminderSnapshot.apply(to:lists:for:now:)`, which resolves it by identifier before writing
/// anything (`ReminderSnapshotListTests`). These source pins fail if `applyReminderSnapshot` goes
/// back to a title lookup, writes a field itself or stops refreshing first, or if an arm writes
/// to the reminder before the list is resolved. Comments are stripped, so commented-out code does
/// not satisfy a pin.
final class ReminderUndoWiringTests: XCTestCase {
    private func managerSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/CheICalMCP/EventKit/EventKitManager.swift"),
                          encoding: .utf8)
    }

    /// The text from `start` up to the first `end` after it, without comments.
    private func slice(_ source: String, from start: String, to end: String) throws -> String {
        let lower = try XCTUnwrap(source.range(of: start), "missing \(start)")
        let upper = source.range(of: end, range: lower.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        return Self.strippingComments(String(source[lower.lowerBound..<upper]))
    }

    /// Drops `//` and `/* */` comments, keeping string literals. A single-line string cannot span
    /// lines, so the string state is reset at every newline.
    static func strippingComments(_ source: String) -> String {
        let chars = Array(source)
        var result = ""
        var inString = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "\n" {
                inString = false
                result.append(c)
                i += 1
            } else if inString {
                result.append(c)
                if c == "\\", let next, next != "\n" {
                    result.append(next)
                    i += 2
                    continue
                }
                if c == "\"" { inString = false }
                i += 1
            } else if c == "/" && next == "/" {
                while i < chars.count && chars[i] != "\n" { i += 1 }
            } else if c == "/" && next == "*" {
                i += 2
                while i + 1 < chars.count && !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                i += 2
            } else {
                if c == "\"" { inString = true }
                result.append(c)
                i += 1
            }
        }
        return result
    }

    func testTheStripperDropsCommentsAndKeepsStrings() {
        let code = "a() // b()\n/* c() */ d(\"// e\")\n"
        XCTAssertEqual(Self.strippingComments(code), "a() \n d(\"// e\")\n")
    }

    /// Refresh first (a list created or synced since this server's last write must not be judged
    /// missing), then the one call that resolves the list and writes the fields; no title lookup
    /// and no field written here.
    func testApplyReminderSnapshotRefreshesThenResolvesThroughTheSnapshot() throws {
        let body = try slice(try managerSource(), from: "private func applyReminderSnapshot(", to: "\n    }\n")
        let refresh = try XCTUnwrap(body.range(of: "refreshIfNeeded()"), body)
        let apply = try XCTUnwrap(body.range(of: "try snapshot.apply(to: reminder, lists: eventStore.calendars(for: .reminder), for: kind, now:"), body)
        XCTAssertLessThan(refresh.lowerBound, apply.lowerBound, body)
        XCTAssertFalse(body.contains(".title"), body)
        XCTAssertFalse(body.contains("reminder."), body)
    }

    /// Each arm passes its kind, and nothing is written to the reminder before the call.
    func testTheUndoArmsResolveTheListBeforeWritingAnything() throws {
        let undo = try slice(try managerSource(), from: "func executeUndo(", to: "func executeRedo(")
        let arms = [("case .deleteReminder(let snapshot):", "try applyReminderSnapshot(snapshot, to: reminder, for: .recreateDeleted)"),
                    ("case .updateReminder(_, let oldSnapshot, _):", "try applyReminderSnapshot(oldSnapshot, to: reminder, for: .revertUpdate)")]
        for (start, call) in arms {
            let arm = try slice(undo, from: start, to: "\n        case .")
            let callRange = try XCTUnwrap(arm.range(of: call), arm)
            XCTAssertFalse(arm[..<callRange.lowerBound].contains("reminder."), arm)
        }
    }
}
