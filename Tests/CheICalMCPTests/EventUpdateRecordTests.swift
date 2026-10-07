import EventKit
import XCTest
@testable import CheICalMCP

/// #246: an `update_event` that moves the event to a calendar in another account changes its
/// identifier (#226, on device). The undo record has to carry the identifier the event has after
/// the save, or the undo looks the event up under the old one and fails as not found.
final class EventUpdateRecordTests: XCTestCase {
    private let store = EKEventStore()

    private func snapshot(title: String) -> EventSnapshot {
        let event = EKEvent(eventStore: store)
        event.calendar = EKCalendar(for: .event, eventStore: store)
        event.title = title
        event.startDate = Date(timeIntervalSince1970: 1_800_000_000)
        event.endDate = event.startDate.addingTimeInterval(3600)
        return EventSnapshot(from: event)
    }

    func testAOneOffUpdateRecordsTheIdentifierTheEventHasAfterTheSave() throws {
        var postStateReads: [String] = []
        let op = EventUpdateRecord.operation(
            requestedID: "before-save", identifierAfterSave: "after-save", oldSnapshot: snapshot(title: "Before"),
            recurringKind: nil, postState: { postStateReads.append($0); return self.snapshot(title: "After") })

        guard case .updateEvent(let id, let old, let saved) = op else { return XCTFail("\(op)") }
        XCTAssertEqual(id, "after-save")
        XCTAssertEqual(old.title, "Before")
        XCTAssertEqual(saved.title, "After")
        XCTAssertEqual(postStateReads, ["after-save"], "the post-state is read the way undo reads it")
        guard case .event(let lookupID, _, _, _)? = op.undoPostState else { return XCTFail("\(op)") }
        XCTAssertEqual(lookupID, "after-save", "undo looks the event up under this identifier")
    }

    func testARecurringUpdateMarkerCarriesTheIdentifierAfterTheSave() {
        var postStateReads: [String] = []
        let op = EventUpdateRecord.operation(
            requestedID: "before-save", identifierAfterSave: "after-save", oldSnapshot: snapshot(title: "Weekly"),
            recurringKind: .series, postState: { postStateReads.append($0); return self.snapshot(title: "x") })

        guard case .updateRecurringEvent(let id, let title, let kind) = op else { return XCTFail("\(op)") }
        XCTAssertEqual(id, "after-save")
        XCTAssertEqual(title, "Weekly")
        XCTAssertEqual(kind, .series)
        XCTAssertEqual(postStateReads, [], "a marker restores nothing, so it reads no post-state")
    }

    /// The event normally has an identifier after a save; if it has none, the requested one is
    /// the best the record can hold (the undo then fails as not found and keeps the record).
    func testTheRequestedIdentifierIsTheFallbackWhenTheSavedEventHasNone() {
        let op = EventUpdateRecord.operation(
            requestedID: "before-save", identifierAfterSave: nil, oldSnapshot: snapshot(title: "Before"),
            recurringKind: nil, postState: { _ in self.snapshot(title: "After") })

        guard case .updateEvent(let id, _, _) = op else { return XCTFail("\(op)") }
        XCTAssertEqual(id, "before-save")
    }

    // MARK: - updateEvent records through the seam

    /// The tests above pin the seam; this pins its one caller. `updateEvent` has to hand the seam
    /// the identifier read off the event after the save. Passing the requested `identifier` there,
    /// or recording `.updateEvent` / `.updateRecurringEvent` directly, brings #246 back.
    func testUpdateEventRecordsThroughTheSeamWithTheIdentifierReadAfterTheSave() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheICalMCP/EventKit")
        let manager = try String(contentsOf: sources.appendingPathComponent("EventKitManager.swift"), encoding: .utf8)
        let code = manager.components(separatedBy: "\n")
            .map { $0.components(separatedBy: "//").first ?? $0 }.joined(separator: "\n")

        let calls = code.components(separatedBy: "EventUpdateRecord.operation(").dropFirst()
        XCTAssertEqual(calls.count, 1, "updateEvent builds its undo record with EventUpdateRecord.operation")
        let arguments = calls.first.map { String($0.prefix(while: { $0 != "}" })) } ?? ""
        XCTAssertTrue(arguments.contains("identifierAfterSave: event.eventIdentifier"), arguments)
        XCTAssertFalse(code.contains("record(.updateEvent("), "record .updateEvent through EventUpdateRecord")
        XCTAssertFalse(code.contains("record(.updateRecurringEvent("), "record the marker through EventUpdateRecord")
    }
}
