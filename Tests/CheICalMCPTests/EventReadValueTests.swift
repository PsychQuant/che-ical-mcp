import CheMCPKit
import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #490: `EventReadValue` copies every accessor `formatEventDict` reads, on the manager's actor, so
/// the response formatted from the value is byte-identical to the one formatted from the live
/// `EKEvent`. Events are built in an in-memory store (no TCC). Attendees, the organizer and an
/// occurrence edited on its own cannot be built there (`EKParticipant` cannot be constructed, an
/// occurrence cannot be detached without a saved series); they reach the formatter through the same
/// accessors and are covered with `FakeFormattableEvent`.
final class EventReadValueTests: XCTestCase {
    private var store: EKEventStore { SharedTestStore.store }
    private let base = ISO8601DateFormatter().date(from: "2027-03-01T02:00:00Z")!

    private func event(_ configure: (EKEvent) -> Void) -> EKEvent {
        let event = EKEvent(eventStore: store)
        event.calendar = EKCalendar(for: .event, eventStore: store)
        event.calendar.title = "#490 calendar"
        event.title = "#490 event"
        event.startDate = base
        event.endDate = base.addingTimeInterval(3600)
        configure(event)
        return event
    }

    /// The kinds of event the issue names, built in memory.
    private var representative: [(String, EKEvent)] {
        [
            ("plain", event { _ in }),
            ("all-day", event {
                $0.isAllDay = true
                $0.timeZone = nil
            }),
            ("time zone, location, notes, url", event {
                $0.timeZone = TimeZone(identifier: "Asia/Tokyo")
                $0.location = "Room 101"
                $0.notes = "notes"
                $0.url = URL(string: "https://example.com/490")
            }),
            ("structured location", event {
                let structured = EKStructuredLocation(title: "Venue")
                structured.geoLocation = CLLocation(latitude: 25.04, longitude: 121.61)
                structured.radius = 150
                $0.structuredLocation = structured
            }),
            ("alarms", event {
                $0.alarms = [EKAlarm(relativeOffset: -900), EKAlarm(absoluteDate: self.base.addingTimeInterval(-7200))]
            }),
            ("weekly with days and an end date", event {
                $0.recurrenceRules = [EKRecurrenceRule(
                    recurrenceWith: .weekly, interval: 1, daysOfTheWeek: [EKRecurrenceDayOfWeek(.monday), EKRecurrenceDayOfWeek(.wednesday)],
                    daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil,
                    end: EKRecurrenceEnd(end: self.base.addingTimeInterval(86_400 * 60)))]
            }),
            ("monthly by count", event {
                $0.recurrenceRules = [EKRecurrenceRule(
                    recurrenceWith: .monthly, interval: 2, daysOfTheWeek: nil, daysOfTheMonth: [1, 15],
                    monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil,
                    end: EKRecurrenceEnd(occurrenceCount: 6))]
            }),
            ("daily, all-day", event {
                $0.isAllDay = true
                $0.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)]
            }),
            // PR #495 round 1: more shapes.
            ("floating timed", event {
                $0.timeZone = nil
            }),
            ("proximity alarm beside a relative one", event {
                let alarm = EKAlarm(relativeOffset: -600)
                let place = EKStructuredLocation(title: "Office")
                place.geoLocation = CLLocation(latitude: 25.0, longitude: 121.5)
                place.radius = 100
                alarm.structuredLocation = place
                alarm.proximity = .enter
                $0.alarms = [alarm, EKAlarm(relativeOffset: -300)]
            }),
            ("yearly", event {
                $0.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: EKRecurrenceEnd(occurrenceCount: 3))]
            }),
            ("weekly, no end", event {
                $0.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil)]
            })
        ]
    }

    /// The shapes a handler formats with: the default, each detail level, a `fields` filter, and a
    /// `display_timezone`.
    private let options: [(detail: String, zone: TimeZone?, fields: Set<String>?)] = [
        ("standard", nil, nil),
        ("summary", nil, nil),
        ("standard", TimeZone(identifier: "America/Los_Angeles"), nil),
        ("summary", nil, ["title", "recurrence_rules", "alarms", "structured_location", "item_timezone"]),
        ("summary", nil, ["attendees", "organizer", "notes"])
    ]

    private func json(_ dict: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]), as: UTF8.self)
    }

    private func assertSame(_ source: some EventFormattingSource, _ label: String, server: CheICalMCPServer) throws {
        let value = EventReadValue(source)
        for option in options {
            let live = server.formatEventDict(source, detailLevel: option.detail, displayTimezone: option.zone, fields: option.fields)
            let copied = server.formatEventDict(value, detailLevel: option.detail, displayTimezone: option.zone, fields: option.fields)
            XCTAssertEqual(try json(copied), try json(live), "\(label) \(option)")
            XCTAssertEqual(try formatJSON(copied), try formatJSON(live), "\(label) \(option): the wire text")
        }
    }

    func testAValueFormatsByteForByteAsTheEvent() async throws {
        let server = try await CheICalMCPServer()
        for (label, event) in representative {
            try assertSame(event, label, server: server)
        }
    }

    /// Attendees, the organizer and every other fragment set, as an edited occurrence or an invite
    /// would have them (`FakeFormattableEvent` sets every conditional accessor).
    func testAValueCarriesEveryFragmentOfAFake() async throws {
        let server = try await CheICalMCPServer()
        var fake = FakeFormattableEvent()
        fake.attendeesFragment = [["name": "A", "status": "accepted"], ["email_redacted": true]]
        fake.organizerFragment = ["name": "O", "is_current_user": false]
        try assertSame(fake, "fake with attendees", server: server)
        try assertSame(FakeFormattableEvent(formatSourceTimeZone: nil, formatIsAllDay: true), "fake all-day", server: server)
    }

    /// The value keeps the dates and flag the handlers filter and sort on.
    func testAValueKeepsTheFieldsTheHandlersFilterOn() {
        let all = event { $0.isAllDay = true }
        let value = EventReadValue(all)
        XCTAssertEqual(value.formatStartDate, all.startDate)
        XCTAssertEqual(value.formatEndDate, all.endDate)
        XCTAssertTrue(value.formatIsAllDay)
    }

    /// `list_calendars` rows from a value: the keys and values the handler always wrote.
    func testACalendarValueListsTheSameRow() {
        let value = CalendarReadValue(identifier: "C1", title: "#490", typeRawValue: EKCalendarType.calDAV.rawValue,
                                      allowsContentModifications: true, isSubscribed: false,
                                      sourceTitle: "iCloud", sourceType: .calDAV)
        let row = value.listedRow
        XCTAssertEqual(row["id"] as? String, "C1")
        XCTAssertEqual(row["title"] as? String, "#490")
        XCTAssertEqual(row["type"] as? Int, EKCalendarType.calDAV.rawValue)
        XCTAssertEqual(row["allowsContentModifications"] as? Bool, true)
        XCTAssertEqual(row["isSubscribed"] as? Bool, false)
        XCTAssertEqual(row["source"] as? String, "iCloud")
        XCTAssertEqual(row["source_type"] as? String, "CalDAV")
        XCTAssertEqual(Set(row.keys), ["id", "title", "type", "allowsContentModifications", "isSubscribed", "source", "source_type"])
        let names: [(EKSourceType, String)] = [(.local, "Local"), (.exchange, "Exchange"), (.calDAV, "CalDAV"), (.mobileMe, "iCloud"),
                                               (.subscribed, "Subscribed"), (.birthdays, "Birthdays")]
        for (type, name) in names {
            XCTAssertEqual(CalendarReadValue.sourceTypeName(type), name)
        }
    }

    /// PR #495 round 1: `CalendarReadValue.init(EKCalendar)` on an in-memory calendar, which has no
    /// source: the row says so (`""`, `Unknown`) instead of trapping on the implicitly unwrapped
    /// `source` as the handler used to.
    func testACalendarValueIsReadFromAnEKCalendar() {
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "#490 in memory"
        let value = CalendarReadValue(calendar)
        XCTAssertEqual(value.identifier, calendar.calendarIdentifier)
        XCTAssertEqual(value.title, "#490 in memory")
        XCTAssertEqual(value.typeRawValue, calendar.type.rawValue)
        XCTAssertEqual(value.allowsContentModifications, calendar.allowsContentModifications)
        XCTAssertEqual(value.isSubscribed, calendar.isSubscribed)
        XCTAssertEqual(value.sourceTitle, "")
        XCTAssertNil(value.sourceType)
        XCTAssertEqual(value.listedRow["source_type"] as? String, "Unknown")
    }

    /// PR #495 round 1: `picking` reads three light fields of every event, then copies whole only
    /// the rows the handler keeps, in the order it gives (an index out of range is skipped).
    func testPickingCopiesOnlyTheKeptRows() {
        let counter = TitleReadCounter()
        let events = (0..<100).map { index in
            CountingEvent(counter: counter, event: FakeFormattableEvent(formatTitle: "\(index)",
                                                                       formatStartDate: base.addingTimeInterval(Double(index) * 60)))
        }
        let picked = EventRowsPicked.picking(events) { keys -> (keep: [Int], info: Int) in
            XCTAssertEqual(keys.map(\.index), Array(0..<100))
            XCTAssertEqual(keys[7].start, events[7].event.formatStartDate)
            return ([42, 7, 1000], keys.count)
        }
        XCTAssertEqual(picked.values.map(\.formatTitle), ["42", "7"])
        XCTAssertEqual(picked.info, 100)
        XCTAssertEqual(counter.reads, 2, "only the two kept rows were copied whole")
    }
}

private final class TitleReadCounter: @unchecked Sendable {
    var reads = 0
}

/// Counts full copies: `EventReadKey` reads no title, `EventReadValue` does.
private struct CountingEvent: EventFormattingSource {
    let counter: TitleReadCounter
    let event: FakeFormattableEvent

    var formatID: String? { event.formatID }
    var formatTitle: String? { counter.reads += 1; return event.formatTitle }
    var formatStartDate: Date { event.formatStartDate }
    var formatEndDate: Date { event.formatEndDate }
    var formatSourceTimeZone: TimeZone? { event.formatSourceTimeZone }
    var formatIsAllDay: Bool { event.formatIsAllDay }
    var formatCalendarTitle: String { event.formatCalendarTitle }
    var formatLocation: String? { event.formatLocation }
    var formatNotes: String? { event.formatNotes }
    var formatURL: URL? { event.formatURL }
    var recurrenceRulesFragment: [[String: Any]]? { event.recurrenceRulesFragment }
    var structuredLocationFragment: [String: Any]? { event.structuredLocationFragment }
    var attendeesFragment: [[String: Any]]? { event.attendeesFragment }
    var organizerFragment: [String: Any]? { event.organizerFragment }
    var alarmsFragment: [ReminderReadSnapshot.Alarm] { event.alarmsFragment }
}
