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
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        _ = try await server.executeToolCall(name: "create_reminder", arguments: [
            "title": .string("Report"), "due_date": .string("2026-11-30T10:00:00+08:00"), "recurrence": weekly("2026-12-14")])
        let rules = await fake.rules
        XCTAssertEqual(rules.first??.endDate, lastSecond(of: "2026-12-14", in: .current))
    }

    func testUpdateReminderStoresADateOnlyEndAsTheLastSecondOfThatDay() async throws {
        let fake = RecordingReminderWrites()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
        _ = try await server.executeToolCall(name: "update_reminder", arguments: [
            "reminder_id": .string("r"), "recurrence": weekly("2026-12-14")])
        let rules = await fake.rules
        XCTAssertEqual(rules.first??.endDate, lastSecond(of: "2026-12-14", in: .current))
    }

    func testADateTimeEndIsStoredAsGiven() async throws {
        let fake = RecordingReminderWrites()
        let server = try await CheICalMCPServer(reminderWriteSource: fake)
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
        let server = try await CheICalMCPServer(eventWriteSource: fake)
        _ = try await server.executeToolCall(name: "create_event", arguments: eventArguments("2026-12-14", zone: "America/New_York"))
        let creates = await fake.creates
        XCTAssertEqual(creates.first?.recurrenceRule?.endDate, instant("2026-12-14T23:59:59-05:00"))
    }

    func testCreateEventsBatchReadsTheDateInTheRowsZone() async throws {
        let fake = FakeEventWriteSource()
        let server = try await CheICalMCPServer(eventWriteSource: fake)
        _ = try await server.executeToolCall(name: "create_events_batch", arguments: [
            "events": .array([.object(eventArguments("2026-12-14", zone: "Asia/Taipei"))])])
        let creates = await fake.creates
        XCTAssertEqual(creates.first?.recurrenceRule?.endDate, instant("2026-12-14T23:59:59+08:00"))
    }

    func testUpdateEventReadsTheDateInTheEventsZone() async throws {
        let fake = FakeEventWriteSource()
        let server = try await CheICalMCPServer(eventWriteSource: fake)
        _ = try await server.executeToolCall(name: "update_event", arguments: [
            "event_id": .string("series"), "span": .string("all"), "timezone": .string("Asia/Taipei"), "recurrence": weekly("2026-12-14")])
        let updates = await fake.updates
        XCTAssertEqual(updates.first?.recurrenceRule?.endDate, instant("2026-12-14T23:59:59+08:00"))
    }

    func testAnEventDateTimeEndIsStoredAsGiven() async throws {
        let fake = FakeEventWriteSource()
        let server = try await CheICalMCPServer(eventWriteSource: fake)
        _ = try await server.executeToolCall(name: "create_event", arguments: eventArguments("2026-12-14T10:00:00", zone: "Asia/Taipei"))
        let creates = await fake.creates
        XCTAssertEqual(creates.first?.recurrenceRule?.endDate, instant("2026-12-14T10:00:00+08:00"), "read in the event's zone, unchanged")
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
            XCTAssertEqual(text.components(separatedBy: "a date only (YYYY-MM-DD) includes that day").count - 1, 1, "\(name): \(text)")
            XCTAssertFalse(text.contains("stops before that day"), "\(name): \(text)")
            XCTAssertEqual(text.components(separatedBy: "so that day's occurrence is kept (#584)").count - 1, 1, "\(name): \(text)")
            let zone = name.hasSuffix("reminder") ? "in this Mac's time zone" : "timezone (else this Mac's)"
            XCTAssertTrue(text.contains(zone), "\(name): \(text)")
        }
    }
}
