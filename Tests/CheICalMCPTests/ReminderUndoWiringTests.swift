import XCTest

/// #242 (PR #277 verify rounds 1 and 2): the reminder undo arms reach the list only through
/// `ReminderSnapshot.apply(to:lists:for:now:)`, which resolves it by identifier before writing
/// anything (`ReminderSnapshotListTests`), and read the lists only through
/// `reminderListsForRestore()`, the entry a batch pre-check shares (PR #282). These source pins
/// fail if that entry stops checking access or refreshing first, if `applyReminderSnapshot` reads
/// the lists itself, goes back to a title lookup or writes a field itself, if an arm creates or
/// writes to the reminder before the lists are read, or if another read of the lists appears on
/// the undo path. Comments are stripped, so commented-out code does not satisfy a pin.
final class ReminderUndoWiringTests: XCTestCase {
    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/CheICalMCP/EventKit/\(file)"), encoding: .utf8)
    }

    private func managerSource() throws -> String {
        try source("EventKitManager.swift")
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

    /// Reminders access first (without it the store lists no list, so every recorded list would be
    /// judged missing), then the refresh, then the read.
    func testReminderListsForRestoreChecksAccessThenRefreshesThenReads() throws {
        let body = try slice(try managerSource(), from: "func reminderListsForRestore() async throws -> [EKCalendar] {", to: "\n    }\n")
        let access = try XCTUnwrap(body.range(of: "try await ensureReminderAccess()"), body)
        let refresh = try XCTUnwrap(body.range(of: "refreshIfNeeded()"), body)
        let read = try XCTUnwrap(body.range(of: "return eventStore.calendars(for: .reminder)"), body)
        XCTAssertLessThan(access.lowerBound, refresh.lowerBound, body)
        XCTAssertLessThan(refresh.lowerBound, read.lowerBound, body)
    }

    /// The lists through the shared entry, then the reminder (the delete-undo arm creates it only
    /// now), then the one call that resolves the list and writes the fields; no other read of the
    /// lists, no title lookup and no field written here.
    func testApplyReminderSnapshotReadsTheListsBeforeItGetsTheReminder() throws {
        let body = try slice(try managerSource(), from: "private func applyReminderSnapshot(", to: "\n    }\n")
        let lists = try XCTUnwrap(body.range(of: "let lists = try await reminderListsForRestore()"), body)
        let target = try XCTUnwrap(body.range(of: "let reminder = try await target()"), body)
        let apply = try XCTUnwrap(body.range(of: "try snapshot.apply(to: reminder, lists: lists, for: kind, now:"), body)
        XCTAssertLessThan(lists.lowerBound, target.lowerBound, body)
        XCTAssertLessThan(target.lowerBound, apply.lowerBound, body)
        XCTAssertFalse(body.contains("calendars(for:"), body)
        XCTAssertFalse(body.contains(".title"), body)
        XCTAssertFalse(body.contains("reminder."), body)
    }

    /// Each arm passes its kind and hands the reminder over as a closure, so it is created or
    /// fetched after the lists are read; nothing creates or writes a reminder before the call.
    func testTheUndoArmsResolveTheListBeforeWritingAnything() throws {
        let undo = try slice(try managerSource(), from: "func executeUndo(", to: "func executeRedo(")
        // #261: the delete arm (single and batch) recreates through `restoreDeletedReminder`.
        XCTAssertTrue(undo.contains("case .deleteReminder(let snapshot):\n            return restoredReminderMessage(try await restoreDeletedReminder(snapshot))"), undo)
        let arms = [("func restoreDeletedReminder(",
                     "let reminder = try await applyReminderSnapshot(snapshot, for: .recreateDeleted, into: { EKReminder(eventStore: eventStore) })"),
                    ("case .updateReminder(_, let oldSnapshot, _):",
                     "let reminder = try await applyReminderSnapshot(oldSnapshot, for: .revertUpdate, into: { try await verifiedReminder(of: operation, verb: .undo) })")]
        for (start, call) in arms {
            let arm = try slice(undo, from: start, to: "\n        case .")
            let callRange = try XCTUnwrap(arm.range(of: call), arm)
            let before = arm[..<callRange.lowerBound]
            XCTAssertFalse(before.contains("reminder."), arm)
            XCTAssertFalse(before.contains("EKReminder("), arm)
        }
    }

    /// No other read of the reminder lists on the undo path: not in the undo arms, and not in the
    /// history-target guard, where a batch undo's pre-check lives (PR #282).
    func testTheUndoPathReadsTheListsOnlyThroughTheSharedEntry() throws {
        let undo = try slice(try managerSource(), from: "func executeUndo(", to: "func executeRedo(")
        XCTAssertFalse(undo.contains("calendars(for: .reminder)"), undo)
        let guardSource = Self.strippingComments(try source("EventKitManager+UndoGuard.swift"))
        XCTAssertFalse(guardSource.contains("calendars(for: .reminder)"))
    }
}
