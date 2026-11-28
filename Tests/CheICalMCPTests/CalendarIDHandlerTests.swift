import EventKit
import MCP
import XCTest
@testable import CheICalMCP

/// #604: `calendar_id` through the handlers, the refusal texts, and `entity_types` of `list_calendars`.
/// Every source is a double (`DispatchProbe` for the ones a test does not replace), so no test reads or
/// writes the live Calendar or Reminders store.
final class CalendarIDHandlerTests: XCTestCase {
    /// Records what the handlers pass to the range reads, answering with no events.
    private actor RangeRecorder: EventRangeReadSource {
        struct Seen: Equatable { let tool: String; let name: String?; let source: String?; let id: String? }
        private(set) var seen: [Seen] = []

        func listEventValues<Info: Sendable>(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                                             pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info> {
            throw ToolError.invalidParameter("the old read must not be reached by a handler")
        }
        func searchEventValues<Info: Sendable>(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?,
                                               calendarName: String?, calendarSource: String?,
                                               pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info> {
            throw ToolError.invalidParameter("the old read must not be reached by a handler")
        }
        func checkConflictValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                                 excludeEventId: String?) async throws -> [EventReadValue] {
            throw ToolError.invalidParameter("the old read must not be reached by a handler")
        }

        func listEventValues<Info: Sendable>(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                                             calendarID: String?, pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info> {
            seen.append(Seen(tool: "list", name: calendarName, source: calendarSource, id: calendarID))
            return EventRowsPicked.picking([EKEvent](), pick)
        }
        func searchEventValues<Info: Sendable>(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?,
                                               calendarName: String?, calendarSource: String?, calendarID: String?,
                                               pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info> {
            seen.append(Seen(tool: "search", name: calendarName, source: calendarSource, id: calendarID))
            return EventRowsPicked.picking([EKEvent](), pick)
        }
        func checkConflictValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                                 calendarID: String?, excludeEventId: String?) async throws -> [EventReadValue] {
            seen.append(Seen(tool: "conflicts", name: calendarName, source: calendarSource, id: calendarID))
            return []
        }
    }

    /// A source that has only the reads that existed before #604, as every older test double does.
    private struct OldRangeSource: EventRangeReadSource {
        func listEventValues<Info: Sendable>(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                                             pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info> {
            EventRowsPicked.picking([EKEvent](), pick)
        }
        func searchEventValues<Info: Sendable>(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?,
                                               calendarName: String?, calendarSource: String?,
                                               pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info> {
            EventRowsPicked.picking([EKEvent](), pick)
        }
        func checkConflictValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                                 excludeEventId: String?) async throws -> [EventReadValue] { [] }
    }

    private struct CalendarListFake: CalendarListSource {
        let rows: [CalendarReadValue]
        func listCalendarValues(for entityType: EKEntityType?) async throws -> [CalendarReadValue] { rows }
    }

    private func server(range: (any EventRangeReadSource)? = nil, write: (any EventWriteSource)? = nil,
                        list: (any CalendarListSource)? = nil) async throws -> CheICalMCPServer {
        let probe = DispatchProbe()
        return try await CheICalMCPServer(
            reminderCleanupSource: probe, reminderReadSource: probe, eventCopySource: probe,
            eventWriteSource: write ?? probe, eventDeletionSource: probe, calendarDeletionSource: probe,
            calendarWriteSource: probe, eventBatchDeletionSource: probe, duplicateSearchSource: probe,
            eventRangeReadSource: range ?? probe, calendarListSource: list ?? probe, reminderWriteSource: probe,
            undoManager: CalendarUndoManager(), reminderCompletionSource: probe, undoExecutionSource: probe)
    }

    private let id = "A1B2-C3"

    // MARK: calendar_id reaches the sources

    func testTheEventReadToolsPassCalendarIDToTheirSource() async throws {
        let recorder = RangeRecorder()
        let server = try await server(range: recorder)
        let range: [String: Value] = ["start_date": .string("2027-04-10"), "end_date": .string("2027-04-11"), "calendar_id": .string(id)]
        _ = try await server.executeToolCall(name: "list_events", arguments: range)
        _ = try await server.executeToolCall(name: "list_events_quick", arguments: ["range": .string("today"), "calendar_id": .string(id)])
        _ = try await server.executeToolCall(name: "search_events", arguments: ["keyword": .string("x"), "calendar_id": .string(id)])
        _ = try await server.executeToolCall(name: "check_conflicts", arguments: [
            "start_time": .string("2027-04-10T09:00:00"), "end_time": .string("2027-04-10T10:00:00"), "calendar_id": .string(id)])
        let seen = await recorder.seen
        XCTAssertEqual(seen.map(\.tool), ["list", "list", "search", "conflicts"])
        XCTAssertTrue(seen.allSatisfy { $0.id == id && $0.name == nil && $0.source == nil }, "\(seen)")
    }

    func testTheNameAndSourceStillReachTheSourceBesideAnID() async throws {
        let recorder = RangeRecorder()
        let server = try await server(range: recorder)
        _ = try await server.executeToolCall(name: "list_events", arguments: [
            "start_date": .string("2027-04-10"), "end_date": .string("2027-04-11"),
            "calendar_name": .string("Calendar A"), "calendar_source": .string("iCloud"), "calendar_id": .string(id)])
        let seen = await recorder.seen
        XCTAssertEqual(seen, [RangeRecorder.Seen(tool: "list", name: "Calendar A", source: "iCloud", id: id)])
    }

    func testAReadWithoutAnIDPassesNilSoOlderDoublesKeepWorking() async throws {
        let server = try await server(range: OldRangeSource())
        let raw = try await server.executeToolCall(name: "list_events", arguments: [
            "start_date": .string("2027-04-10"), "end_date": .string("2027-04-11"), "calendar_name": .string("Work")])
        XCTAssertTrue(raw.contains("event_count"), raw)
    }

    func testASourceWithoutIDSupportRefusesACallThatHasOne() async throws {
        let server = try await server(range: OldRangeSource())
        do {
            _ = try await server.executeToolCall(name: "list_events", arguments: [
                "start_date": .string("2027-04-10"), "end_date": .string("2027-04-11"), "calendar_id": .string(id)])
            XCTFail("a source that cannot take an id must refuse one, not drop it")
        } catch {
            XCTAssertTrue(String(describing: error).contains("calendar_id is not supported"), String(describing: error))
        }
    }

    func testCreateUpdateAndBatchRowsPassCalendarIDToTheWriteSource() async throws {
        let fake = FakeEventWriteSource()
        let server = try await server(write: fake)
        _ = try await server.executeToolCall(name: "create_event", arguments: [
            "title": .string("Talk"), "start_time": .string("2027-04-10T09:00:00"), "end_time": .string("2027-04-10T10:00:00"),
            "calendar_id": .string(id)])
        _ = try await server.executeToolCall(name: "update_event", arguments: ["event_id": .string("e1"), "calendar_id": .string(id)])
        _ = try await server.executeToolCall(name: "create_events_batch", arguments: ["events": .array([.object([
            "title": .string("Row"), "start_time": .string("2027-04-10T09:00:00"), "end_time": .string("2027-04-10T10:00:00"),
            "calendar_id": .string(id)])])])
        let creates = await fake.creates
        let updates = await fake.updates
        XCTAssertEqual(creates.map(\.calendarID), [id, id])
        XCTAssertTrue(creates.allSatisfy { $0.calendarName == nil })
        XCTAssertEqual(updates.map(\.calendarID), [id])
    }

    // MARK: the schema

    func testEveryEventToolDeclaresCalendarIDAndNoLongerRequiresACalendarName() throws {
        let tools = CheICalMCPServer.defineTools()
        for name in ["list_events", "list_events_quick", "search_events", "check_conflicts", "create_event", "update_event"] {
            let schema = try XCTUnwrap(tools.first { $0.name == name }?.inputSchema.objectValue, name)
            let property = schema["properties"]?.objectValue?["calendar_id"]?.objectValue
            XCTAssertEqual(property?["type"]?.stringValue, "string", name)
        }
        let create = try XCTUnwrap(tools.first { $0.name == "create_event" }?.inputSchema.objectValue)
        let createRequired = create["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
        XCTAssertFalse(createRequired.contains("calendar_name"))
        let batch = try XCTUnwrap(tools.first { $0.name == "create_events_batch" }?.inputSchema.objectValue)
        let row = batch["properties"]?.objectValue?["events"]?.objectValue?["items"]?.objectValue
        XCTAssertEqual(row?["properties"]?.objectValue?["calendar_id"]?.objectValue?["type"]?.stringValue, "string")
        XCTAssertFalse((row?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []).contains("calendar_name"))
    }

    func testACalendarIDThatIsNotAStringIsRefusedBeforeTheHandlerRuns() async throws {
        let recorder = RangeRecorder()
        let server = try await server(range: recorder)
        do {
            _ = try await server.executeToolCall(name: "list_events", arguments: [
                "start_date": .string("2027-04-10"), "end_date": .string("2027-04-11"), "calendar_id": .int(5)])
            XCTFail("a number is not a calendar id")
        } catch {
            XCTAssertTrue(String(describing: error).contains("calendar_id"), String(describing: error))
        }
        let seen = await recorder.seen
        XCTAssertTrue(seen.isEmpty)
    }

    // MARK: the refusal texts

    func testTheRefusalTellsACallerWhoHasCalendarIDToPassIt() {
        let text = EventKitErrorSanitizer.sanitizeForResponse(
            EventKitError.sameNameCalendars(count: 2, ids: ["A1B2-C3", "D4E5-F6"], offersID: true)).code
        XCTAssertTrue(text.contains("2 calendars"), text)
        XCTAssertTrue(text.contains("Pass calendar_id"), text)
        XCTAssertTrue(text.contains("A1B2-C3") && text.contains("D4E5-F6"), text)
        XCTAssertFalse(text.contains("rename"), text)
    }

    func testTheRefusalTellsACallerWithoutCalendarIDToRename() {
        let text = EventKitErrorSanitizer.sanitizeForResponse(
            EventKitError.sameNameCalendars(count: 2, ids: [], offersID: false)).code
        XCTAssertTrue(text.contains("rename one of the calendars"), text)
        XCTAssertFalse(text.contains("Pass calendar_id"), text)
    }

    func testTheRefusalListsNoIDsWhenOneIsNotPlain() {
        let ids = CalendarCandidateIDs.listable(["A1B2-C3", "evil\nid"])
        XCTAssertEqual(ids, [])
        let text = EventKitErrorSanitizer.sanitizeForResponse(EventKitError.sameNameCalendars(count: 2, ids: ids, offersID: true)).code
        XCTAssertFalse(text.contains("Their ids"), text)
        XCTAssertFalse(text.contains("evil"), text)
    }

    func testAnIDThatDisagreesWithTheNameIsRefusedInWordsThatEchoNoTitle() {
        let text = EventKitErrorSanitizer.sanitizeForResponse(EventKitError.calendarIDMismatch).code
        XCTAssertTrue(text.contains("calendar_id"), text)
        XCTAssertTrue(text.contains("Nothing was done"), text)
    }

    // MARK: entity types

    /// spec-example: calendar-resolution / entity types of a row
    func testTheExampleOfEntityTypes() async throws {
        let cases: [(EKEntityType?, [String])] = [(.event, ["event"]), (.reminder, ["reminder"]), (nil, ["event", "reminder"])]
        for (requested, kinds) in cases {
            XCTAssertEqual(CalendarKindLists.reads(for: requested).map(\.name), kinds)
            XCTAssertEqual(CalendarKindLists.reads(for: requested).map(\.type), kinds.map { $0 == "event" ? .event : .reminder })
        }
        // The manager reads those lists in that order and tags each row with the list it came from.
        let file = try SourcePins.source("EventRangeReadSource.swift")
        let manager = String(file[try XCTUnwrap(file.range(of: "extension EventKitManager:")).lowerBound...])
        let body = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func listCalendarValues(", in: manager)))
        XCTAssertTrue(body.contains("for read in CalendarKindLists.reads(for: entityType) {"), body)
        XCTAssertTrue(body.contains("try await listCalendars(for: read.type).map { CalendarReadValue($0, entityTypes: [read.name]) }"), body)
    }

    func testListCalendarsPrintsEachRowsEntityTypes() async throws {
        let eventRow = CalendarReadValue(identifier: "E1", title: "Calendar A", typeRawValue: EKCalendarType.calDAV.rawValue,
                                         allowsContentModifications: true, isSubscribed: false, sourceTitle: "iCloud",
                                         sourceType: .mobileMe, entityTypes: ["event"])
        let reminderRow = CalendarReadValue(identifier: "R1", title: "Calendar A", typeRawValue: EKCalendarType.calDAV.rawValue,
                                            allowsContentModifications: true, isSubscribed: false, sourceTitle: "iCloud",
                                            sourceType: .mobileMe, entityTypes: ["reminder"])
        let server = try await server(list: CalendarListFake(rows: [eventRow, reminderRow]))
        let raw = try await server.executeToolCall(name: "list_calendars", arguments: [:])
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.map { $0["id"] as? String }, ["E1", "R1"])
        XCTAssertEqual(rows.map { $0["entity_types"] as? [String] }, [["event"], ["reminder"]])
    }

    func testTheOtherFieldsOfARowAreUnchanged() {
        let row = CalendarReadValue(identifier: "E1", title: "Work", typeRawValue: 2, allowsContentModifications: true,
                                    isSubscribed: false, sourceTitle: "iCloud", sourceType: .calDAV, entityTypes: ["event"]).listedRow
        XCTAssertEqual(Set(row.keys), ["id", "title", "type", "allowsContentModifications", "isSubscribed", "source",
                                       "source_type", "entity_types"])
        XCTAssertEqual(row["source"] as? String, "iCloud")
    }
}
