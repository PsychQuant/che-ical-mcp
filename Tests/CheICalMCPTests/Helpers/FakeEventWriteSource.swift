import Foundation
@testable import CheICalMCP

/// An `EventWriteSource` for the event write handler tests (#268, #372). Identifiers and titles
/// select the outcome:
/// - update with `calendarSource == "Other"`: saved under `moved-<id>` (a cross-account move);
/// - update of an id starting with `allday-`: the stored event is all-day, 2027-04-10 (host zone);
/// - create titled `duplicate`: answered as a duplicate.
actor FakeEventWriteSource: EventWriteSource {
    private(set) var updates: [EventUpdateRequest] = []
    private(set) var creates: [EventCreateRequest] = []

    static let host = Calendar.gregorian(in: .current)
    static var storedStart: Date {
        host.date(from: DateComponents(year: 2027, month: 4, day: 10)) ?? Date(timeIntervalSince1970: 1_807_000_000)
    }

    func updateEventValue(_ request: EventUpdateRequest) async throws -> EventWriteValue {
        updates.append(request)
        let id = request.calendarSource == "Other" ? "moved-" + request.identifier : request.identifier
        let storedAllDay = request.identifier.hasPrefix("allday-")
        let isAllDay = request.isAllDay ?? storedAllDay
        let start = request.startDate ?? Self.storedStart
        let end = request.endDate ?? Self.storedStart.addingTimeInterval(storedAllDay ? 86_399 : 3600)
        return EventWriteValue(eventIdentifier: id, title: request.title ?? "Saved", isAllDay: isAllDay,
                               startDate: isAllDay ? Self.host.startOfDay(for: start) : start, endDate: end)
    }

    func createEventValue(_ request: EventCreateRequest) async throws -> EventCreateValue {
        creates.append(request)
        return EventCreateValue(
            event: EventWriteValue(eventIdentifier: "created-\(creates.count)", title: request.title,
                                   isAllDay: request.isAllDay, startDate: request.startDate, endDate: request.endDate),
            isDuplicate: request.title == "duplicate")
    }

    func similarEventValues(title: String, limit: Int) async throws -> [SimilarEventValue] { [] }

    /// `<day>T<time>` written with an offset one hour behind this Mac's offset on that day, so a
    /// time after 23:00 falls on the next day in the host zone.
    static func behindHost(_ day: String, _ time: String) -> String {
        let noon = host.date(from: DateComponents(year: Int(day.prefix(4)), month: Int(day.dropFirst(5).prefix(2)),
                                                  day: Int(day.suffix(2)), hour: 12)) ?? Date()
        let seconds = host.timeZone.secondsFromGMT(for: noon) - 3600
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        return String(format: "%@T%@%@%02d:%02d", day, time, sign, magnitude / 3600, (magnitude % 3600) / 60)
    }
}
