import MCP
import XCTest
@testable import CheICalMCP

/// #584: a date-only `recurrence.end_date` reaches the store as the last instant of that day, in the
/// zone it is read in (the event's `timezone`, else the host zone), on every write path that shares
/// `parseRecurrenceRule`; a date-time end reaches it unchanged. Reminders read it in the host zone.
private actor RecordingReminderWrites: ReminderWriteSource {
    private(set) var rules: [RecurrenceRuleInput?] = []
    func createReminder(_ request: ReminderCreateRequest) async throws -> EventKitManager.CreateReminderResult {
        rules.append(request.recurrenceRule)
        return .init(reminder: ReminderWriteSnapshot(id: "saved", title: request.title, notes: nil), isDuplicate: false, storeDiffers: [])
    }
    func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderUpdateResult {
        rules.append(request.recurrenceRule)
        return ReminderUpdateResult(reminder: ReminderWriteSnapshot(id: request.identifier, title: "Saved", notes: nil),
                                    dateSync: nil, recurrence: nil)
    }
    func getReminder(identifier: String) async throws -> ReminderWriteSnapshot {
        ReminderWriteSnapshot(id: identifier, title: "Old", notes: nil)
    }
}

final class RecurrenceEndDateHandlerTests: XCTestCase {
    private func instant(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    /// 23:59:59 of `day` in `zone`, built independently of the code under test.
    private func lastSecond(of day: String, in zone: TimeZone) -> Date {
        let parts = day.split(separator: "-").map { Int($0)! }
        return Calendar.gregorian(in: zone).date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                                      hour: 23, minute: 59, second: 59))!
    }

    private func weekly(_ end: String) -> Value {
        .object(["frequency": .string("weekly"), "days_of_week": .array([.int(2)]), "end_date": .string(end)])
    }

    // MARK: reminders (host zone)

    func testCreateReminderStoresADateOnlyEndAsTheLastSecondOfThatDay() async throws {
        let fake = RecordingReminderWrites()
        let server = try await TestServer.make(reminderWriteSource: fake)
        _ = try await server.executeToolCall(name: "create_reminder", arguments: [
            "title": .string("Report"), "due_date": .string("2026-11-30T10:00:00+08:00"), "recurrence": weekly("2026-12-14")])
        let rules = await fake.rules
        XCTAssertEqual(rules.first??.endDate, lastSecond(of: "2026-12-14", in: .current))
    }

    func testUpdateReminderStoresADateOnlyEndAsTheLastSecondOfThatDay() async throws {
        let fake = RecordingReminderWrites()
        let server = try await TestServer.make(reminderWriteSource: fake)
        _ = try await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "recurrence": weekly("2026-12-14")])
        let rules = await fake.rules
        XCTAssertEqual(rules.first??.endDate, lastSecond(of: "2026-12-14", in: .current))
    }

    func testADateTimeEndIsStoredAsGiven() async throws {
        let fake = RecordingReminderWrites()
        let server = try await TestServer.make(reminderWriteSource: fake)
        _ = try await server.executeToolCall(name: "create_reminder", arguments: [
            "title": .string("Report"), "due_date": .string("2026-11-30T10:00:00+08:00"),
            "recurrence": weekly("2026-12-14T00:00:00+08:00")])
        let rules = await fake.rules
        XCTAssertEqual(rules.first??.endDate, instant("2026-12-14T00:00:00+08:00"))
    }

    // MARK: events (the event's zone)

    private func eventArguments(_ end: String, zone: String) -> [String: Value] {
        ["title": .string("Standup"), "timezone": .string(zone), "start_time": .string("2026-11-30T10:00:00"),
         "end_time": .string("2026-11-30T11:00:00"), "recurrence": weekly(end)]
    }

    func testCreateEventReadsTheDateInTheEventsZone() async throws {
        let fake = FakeEventWriteSource()
        let server = try await TestServer.make(eventWriteSource: fake)
        _ = try await server.executeToolCall(name: "create_event", arguments: eventArguments("2026-12-14", zone: "America/New_York"))
        let creates = await fake.creates
        XCTAssertEqual(creates.first?.recurrenceRule?.endDate, instant("2026-12-14T23:59:59-05:00"))
    }

    func testCreateEventsBatchReadsTheDateInTheRowsZone() async throws {
        let fake = FakeEventWriteSource()
        let server = try await TestServer.make(eventWriteSource: fake)
        _ = try await server.executeToolCall(name: "create_events_batch", arguments: [
            "events": .array([.object(eventArguments("2026-12-14", zone: "Asia/Tokyo"))])])
        let creates = await fake.creates
        XCTAssertEqual(creates.first?.recurrenceRule?.endDate, instant("2026-12-14T23:59:59+09:00"))
    }

    func testUpdateEventReadsTheDateInTheZoneTheCallGives() async throws {
        let fake = FakeEventWriteSource()
        let server = try await TestServer.make(eventWriteSource: fake)
        _ = try await server.executeToolCall(name: "update_event", arguments: [
            "event_id": .string("series"), "span": .string("all"), "timezone": .string("Europe/Berlin"), "recurrence": weekly("2026-12-14")])
        let updates = await fake.updates
        XCTAssertEqual(updates.first?.recurrenceRule?.endDate, instant("2026-12-14T23:59:59+01:00"), "the zone the call gives the event")
    }

    /// Without `timezone`, `update_event` reads the day in the stored event's zone (the zone
    /// `occurrence_date` is read in), not this Mac's: a series in New York or in Tokyo, whatever the
    /// host. Both directions: a zone behind and a zone ahead of any test host.
    func testUpdateEventWithoutTimezoneReadsTheDateInTheStoredEventsZone() async throws {
        for (identifier, expected) in [("Pacific/Honolulu", "2026-12-14T23:59:59-10:00"), ("Pacific/Kiritimati", "2026-12-14T23:59:59+14:00")] {
            let fake = FakeEventWriteSource(occurrenceZone: TimeZone(identifier: identifier))
            let server = try await TestServer.make(eventWriteSource: fake)
            _ = try await server.executeToolCall(name: "update_event", arguments: [
                "event_id": .string("series"), "span": .string("all"), "recurrence": weekly("2026-12-14")])
            let updates = await fake.updates
            XCTAssertEqual(updates.first?.recurrenceRule?.endDate, instant(expected), identifier)
            let lookups = await fake.zoneLookups
            XCTAssertEqual(lookups, ["series"], identifier)
        }
    }

    /// A floating event (no stored zone), and `clear_timezone` (the event becomes floating): this Mac's zone.
    func testUpdateEventOfAFloatingEventReadsTheDateInThisMacsZone() async throws {
        let floating = FakeEventWriteSource(occurrenceZone: nil)
        let server = try await TestServer.make(eventWriteSource: floating)
        _ = try await server.executeToolCall(name: "update_event", arguments: [
            "event_id": .string("series"), "span": .string("all"), "recurrence": weekly("2026-12-14")])
        let updates = await floating.updates
        XCTAssertEqual(updates.first?.recurrenceRule?.endDate, lastSecond(of: "2026-12-14", in: .current))

        let zoned = FakeEventWriteSource(occurrenceZone: TimeZone(identifier: "Pacific/Kiritimati"))
        let cleared = try await TestServer.make(eventWriteSource: zoned)
        _ = try await cleared.executeToolCall(name: "update_event", arguments: [
            "event_id": .string("series"), "span": .string("all"), "clear_timezone": .bool(true), "recurrence": weekly("2026-12-14")])
        let clearedUpdates = await zoned.updates
        XCTAssertEqual(clearedUpdates.first?.recurrenceRule?.endDate, lastSecond(of: "2026-12-14", in: .current), "the event becomes floating")
    }

    /// The stored zone is looked up only for a date-only end; a date-time end, or a call with
    /// `timezone`, needs no lookup.
    func testUpdateEventLooksTheZoneUpOnlyForADateOnlyEnd() async throws {
        for arguments in [["recurrence": weekly("2026-12-14T10:00:00+08:00")],
                          ["timezone": .string("Europe/Berlin"), "recurrence": weekly("2026-12-14")]] as [[String: Value]] {
            let fake = FakeEventWriteSource(occurrenceZone: TimeZone(identifier: "Pacific/Kiritimati"))
            let server = try await TestServer.make(eventWriteSource: fake)
            _ = try await server.executeToolCall(name: "update_event", arguments: arguments.merging(["event_id": .string("series"), "span": .string("all")]) { $1 })
            let lookups = await fake.zoneLookups
            XCTAssertEqual(lookups, [], "\(arguments)")
        }
    }

    func testAnEventDateTimeEndIsStoredAsGiven() async throws {
        let fake = FakeEventWriteSource()
        let server = try await TestServer.make(eventWriteSource: fake)
        _ = try await server.executeToolCall(name: "create_event", arguments: eventArguments("2026-12-14T10:00:00", zone: "Asia/Kolkata"))
        let creates = await fake.creates
        XCTAssertEqual(creates.first?.recurrenceRule?.endDate, instant("2026-12-14T10:00:00+05:30"), "read in the event's zone, unchanged")
    }

    // MARK: texts

    /// Every schema with `recurrence.end_date` says a date only includes that day (#584), once.
    func testEveryEndDateDescriptionSaysADateOnlyIncludesThatDay() throws {
        func endDateDescription(_ tool: Tool) -> String? {
            guard case .object(let schema) = tool.inputSchema, case .object(let properties)? = schema["properties"] else { return nil }
            var recurrence = properties["recurrence"]
            if recurrence == nil, case .object(let events)? = properties["events"], case .object(let items)? = events["items"],
               case .object(let itemProperties)? = items["properties"] {
                recurrence = itemProperties["recurrence"]
            }
            guard case .object(let rule)? = recurrence, case .object(let ruleProperties)? = rule["properties"],
                  case .object(let end)? = ruleProperties["end_date"], case .string(let text)? = end["description"] else { return nil }
            return text
        }
        let names = ["create_event", "create_events_batch", "update_event", "create_reminder", "update_reminder"]
        let tools = CheICalMCPServer.defineTools()
        for name in names {
            let tool = try XCTUnwrap(tools.first { $0.name == name }, name)
            let text = try XCTUnwrap(endDateDescription(tool), "\(name) has no recurrence.end_date description")
            XCTAssertFalse(text.contains("stops before that day"), "\(name): \(text)")
            if name.hasSuffix("reminder") {
                // Only what is stored: the reminder side of the end day was not measured.
                XCTAssertEqual(text.components(separatedBy: "a date only (YYYY-MM-DD) is stored as the last second of that day, 23:59:59, in this Mac's time zone, also when the due date has another zone").count - 1, 1, "\(name): \(text)")
                XCTAssertFalse(text.contains("occurrence is kept"), "\(name): \(text)")
            } else {
                XCTAssertEqual(text.components(separatedBy: "a date only (YYYY-MM-DD) includes that day").count - 1, 1, "\(name): \(text)")
                XCTAssertEqual(text.components(separatedBy: "so that day's occurrence is kept (#584)").count - 1, 1, "\(name): \(text)")
                let zone = name == "update_event" ? "in the call's timezone, else the event's own time zone" : "timezone (else this Mac's)"
                XCTAssertTrue(text.contains(zone), "\(name): \(text)")
            }
        }
    }
}
