import XCTest
@testable import CheICalMCP

/// #273: the record sites of the calendar operations and of a plain `copy_event` run against the
/// store, which no unit test reaches, so these pins read `Sources/` (`SourcePins`: one function,
/// comments and string literals blanked). Each fails when its record is removed, moved before the
/// write it records, or recorded for the duplicate answer of `create_calendar`.
final class CalendarUndoRecordWiringTests: XCTestCase {
    private struct Missing: Error, CustomStringConvertible { let description: String }

    private static let manager = "EventKit/EventKitManager.swift"

    private static func body(_ declaration: String) throws -> String {
        guard let body = SourcePins.body(of: declaration, in: try SourcePins.source(manager)) else {
            throw Missing(description: "not found: \(declaration) in \(manager)")
        }
        return body
    }

    /// `literal` as a pattern that tolerates any whitespace around its punctuation and in place of
    /// its spaces, as `UndoBatchWiringTests.call` does.
    private static func call(_ literal: String) -> String {
        var pattern = ""
        for character in literal {
            if character == " " { pattern += #"\s*"#; continue }
            let escaped = NSRegularExpression.escapedPattern(for: String(character))
            pattern += "(),:{}[]".contains(character) ? #"\s*"# + escaped + #"\s*"# : escaped
        }
        return pattern
    }

    private static func offsets(of literal: String, in body: String) -> [Int] {
        SourcePins.ranges(ofPattern: call(literal), in: body).map { body.distance(from: body.startIndex, to: $0.lowerBound) }
    }

    /// The offset of the only match of `literal` in `body`; fails when there is none or more than one.
    private static func only(_ literal: String, in body: String, file: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let found = offsets(of: literal, in: body)
        XCTAssertEqual(found.count, 1, "expected one: \(literal)", file: file, line: line)
        return try XCTUnwrap(found.first, "missing: \(literal)", file: file, line: line)
    }

    /// Recorded once, by the write seam after `createCalendar` returned (its save path is pinned
    /// as is by `NewObjectSaveTests.testEveryNewCalendarIsSavedThroughNewObjectSave`), and never for
    /// the existing calendar a title match returns.
    func testCreateCalendarRecordsItsMarkerAfterTheSaveOnly() throws {
        let create = try Self.body("func createCalendar(title: String, entityType: EKEntityType, color: String? = nil)")
        XCTAssertEqual(Self.offsets(of: "CalendarUndoManager.shared.record(", in: create).count, 0, "recorded by the seam")
        // With its opening brace, so the protocol requirement of the same signature is not read.
        let declaration = "func writeNewCalendar(title: String, entityType: EKEntityType, color: String?) async throws -> CalendarWriteValue {"
        guard let body = SourcePins.body(of: declaration, in: try SourcePins.source("CalendarWriteSource.swift")) else {
            throw Missing(description: "not found: \(declaration)")
        }
        let save = try Self.only("let result = try await createCalendar(title: title, entityType: entityType, color: color)", in: body)
        let gate = try Self.only("if !result.isDuplicate {", in: body)
        let record = try Self.only("await CalendarUndoManager.shared.record(.calendarOperation(kind: .created, title: result.calendar.title))", in: body)
        let back = try Self.only("return CalendarWriteValue(", in: body)
        XCTAssertLessThan(save, gate, "recorded after the create returned")
        XCTAssertLessThan(gate, record, "only for a calendar that was created")
        XCTAssertLessThan(record, back)
        XCTAssertEqual(Self.offsets(of: "CalendarUndoManager.shared.record(", in: body).count, 1)
        // The gate holds only the record: nothing else is skipped for a duplicate.
        let afterGate = body[body.index(body.startIndex, offsetBy: gate)...]
        let closing = body.distance(from: body.startIndex, to: try XCTUnwrap(afterGate.firstIndex(of: "}")))
        XCTAssertGreaterThan(closing, record)
        XCTAssertLessThan(closing, back)
    }

    /// The title before the rename is kept, and the record comes after the save succeeded.
    func testUpdateCalendarRecordsTheTitleBeforeTheUpdateAfterTheSave() throws {
        let body = try Self.body("func updateCalendar(")
        let title = try Self.only("let titleBefore = calendar.title", in: body)
        let rename = try Self.only("if let t = title { calendar.title = t }", in: body)
        let save = try Self.only("let readBack = try saveExistingCalendar(calendar, requested: requested)", in: body)
        let record = try Self.only("await CalendarUndoManager.shared.record(.calendarOperation(kind: .updated, title: titleBefore))", in: body)
        // PR #507 round 2: a save that landed but could not be read back still has its marker, and
        // the list is re-read before the values are applied.
        let unread = try Self.only("guard readBack else { throw EventKitError.writeStoreReadBackFailed(kind: ", in: body)
        // Round 3 LOW 3: a list deleted elsewhere is not found, not a write-store error.
        let refresh = try Self.only("guard calendar.refresh() else { throw EventKitError.calendarNotFound(identifier: identifier) }", in: body)
        XCTAssertEqual(Self.offsets(of: "_ = calendar.refresh()", in: body).count, 0)
        XCTAssertLessThan(title, rename, "the title is read before the rename")
        XCTAssertLessThan(save, record, "recorded after the save")
        XCTAssertLessThan(record, unread, "recorded before a failed read-back is reported")
        XCTAssertLessThan(refresh, title, "the list is re-read before the values are applied")
        XCTAssertEqual(Self.offsets(of: "CalendarUndoManager.shared.record(", in: body).count, 1)
    }

    /// The title is read before the removal (and before the emptiness check's suspension), and the
    /// record comes after the removal succeeded.
    func testDeleteCalendarRecordsTheTitleItHadAfterTheRemoval() throws {
        let body = try Self.body("func deleteCalendar(identifier: String, requireEmpty: Bool = false)")
        let title = try Self.only("let title = calendar.title", in: body)
        // Round 3 LOW 3: re-read first; a list deleted elsewhere is not found.
        let refresh = try Self.only("guard calendar.refresh() else { throw EventKitError.calendarNotFound(identifier: identifier) }", in: body)
        XCTAssertLessThan(refresh, title, "re-read before anything is taken from it")
        let check = try Self.only("if requireEmpty {", in: body)
        let remove = try Self.only("try removeExistingCalendar(calendar)", in: body)
        let record = try Self.only("await CalendarUndoManager.shared.record(.calendarOperation(kind: .deleted, title: title))", in: body)
        XCTAssertLessThan(title, check, "read before the emptiness check")
        XCTAssertLessThan(title, remove, "read before the removal")
        XCTAssertLessThan(remove, record, "recorded after the removal")
        XCTAssertEqual(Self.offsets(of: "CalendarUndoManager.shared.record(", in: body).count, 1)
    }

    /// A plain copy records the copy's create (its undo deletes the copy through the #236 check);
    /// the `delete_original` path does not record here, because `moveEvent` records the move.
    func testAPlainCopyRecordsTheCopysCreate() throws {
        let body = try Self.body("func copyEvent(")
        let save = try Self.only("try EventCopyOperation.saveCopy(", in: body)
        // The `""` fallback of the title is a string literal, blanked by `SourcePins`: pinned in two parts.
        let record = try Self.only("await CalendarUndoManager.shared.record(.createEvent(id: copyID, title: newEvent.title ??", in: body)
        let created = try Self.only("created: postWriteSnapshot(eventID: copyID, saved: newEvent)))", in: body)
        let copyID = try Self.only("let copyID = newEvent.eventIdentifier ??", in: body)
        XCTAssertLessThan(save, copyID)
        XCTAssertLessThan(record, created)
        let back = try Self.only("return (newEvent, Self.fieldsNotCarriedOver(from: sourceEvent, to: newEvent))", in: body)
        XCTAssertLessThan(save, record, "recorded after the save")
        XCTAssertLessThan(record, back)
        XCTAssertEqual(Self.offsets(of: "CalendarUndoManager.shared.record(", in: body).count, 1)

        let move = try Self.body("func moveEventForCopyTool(")
        XCTAssertEqual(Self.offsets(of: "CalendarUndoManager.shared.record(", in: move).count, 0, "moveEvent records the move")
        _ = try Self.only("return try await moveEvent(", in: move)
    }

    /// The undo arm throws the refusal and does nothing else; the redo arm is in the write-nothing list.
    func testTheUndoArmOnlyRefusesAndTheRedoArmWritesNothing() throws {
        let undo = try Self.body("func executeUndo(_ operation: UndoOperation)")
        let start = try XCTUnwrap(undo.range(of: "case .calendarOperation(let kind, _):"))
        let end = try XCTUnwrap(undo.range(of: "case ", range: start.upperBound..<undo.endIndex))
        let arm = String(undo[start.upperBound..<end.lowerBound])
        XCTAssertEqual(arm.trimmingCharacters(in: .whitespacesAndNewlines), "throw UndoOperation.calendarOperationRefusal(kind: kind)", arm)

        let redo = try Self.body("func executeRedo(_ operation: UndoOperation)")
        let list = try XCTUnwrap(redo.range(of: "return operation.redoInstruction ??"))
        let firstCase = try XCTUnwrap(redo.range(of: "case "))
        XCTAssertTrue(redo[firstCase.lowerBound..<list.lowerBound].contains(".calendarOperation"),
                      "the marker is in the write-nothing list")
    }
}
