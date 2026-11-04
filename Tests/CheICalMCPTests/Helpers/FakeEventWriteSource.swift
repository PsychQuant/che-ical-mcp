import Foundation
@testable import CheICalMCP

/// An `EventWriteSource` for the event write handler tests (#268, #372). Identifiers and titles
/// select the outcome:
/// - update with `calendarSource == "Other"`: saved under `moved-<id>` (a cross-account move), and
///   refused with `occurrenceDate` and span this (nothing recorded in `updates`);
/// - update with `occurrenceDate` and span this: a detached occurrence `occurrence-<seconds>` of the
///   series (`seriesIdentifier`); with span future: a new series `split-<id>`;
/// - update of an id starting with `allday-`: the stored event is all-day, 2027-04-10 (host zone);
/// - create titled `duplicate`: answered as a duplicate;
/// - `occurrenceDateTimeZone`: answers `occurrenceZone` (#383) and records the identifier asked for;
///   the identifier `denied` throws `accessDenied`. An occurrence edit (date given, not span all)
///   reports the matched occurrence as starting at that date, in `occurrenceZone`.
actor FakeEventWriteSource: EventWriteSource {
    private(set) var updates: [EventUpdateRequest] = []
    private(set) var creates: [EventCreateRequest] = []
    private(set) var zoneLookups: [String] = []
    private let occurrenceZone: TimeZone?

    init(occurrenceZone: TimeZone? = nil) {
        self.occurrenceZone = occurrenceZone
    }

    func occurrenceDateTimeZone(identifier: String) async throws -> TimeZone? {
        zoneLookups.append(identifier)
        if identifier == "denied" { throw EventKitError.accessDenied(type: "calendar") }
        return occurrenceZone
    }

    static let host = Calendar.gregorian(in: .current)
    static var storedStart: Date {
        host.date(from: DateComponents(year: 2027, month: 4, day: 10)) ?? Date(timeIntervalSince1970: 1_807_000_000)
    }

    func updateEventValue(_ request: EventUpdateRequest) async throws -> EventWriteValue {
        // Verify round 4: an occurrence edit with a calendar of another account is refused before
        // anything is written, as `EventKitManager.updateEvent` does.
        if request.occurrenceDate != nil, request.span == .thisEvent, !request.applyToAll, request.calendarSource == "Other" {
            throw EventKitError.moveRefused(reason: EventKitManager.occurrenceAcrossAccountsReason)
        }
        updates.append(request)
        let series = request.calendarSource == "Other" ? "moved-" + request.identifier : request.identifier
        var id = series
        var seriesIdentifier: String?
        if let occurrence = request.occurrenceDate, !request.applyToAll {
            if request.span == .thisEvent {
                // One occurrence edited on its own: a detached occurrence with an id of its own (an
                // unrelated shape here, so nothing can lean on iCloud's `/RID=`).
                id = "occurrence-\(Int(occurrence.timeIntervalSinceReferenceDate))"
                seriesIdentifier = series
            } else {
                // span future from a later occurrence: EventKit ends the series and starts a new one.
                id = "split-" + series
            }
        }
        let storedAllDay = request.identifier.hasPrefix("allday-")
        let isAllDay = request.isAllDay ?? storedAllDay
        let start = request.startDate ?? Self.storedStart
        let end = request.endDate ?? Self.storedStart.addingTimeInterval(storedAllDay ? 86_399 : 3600)
        var value = EventWriteValue(eventIdentifier: id, title: request.title ?? "Saved", isAllDay: isAllDay,
                                    startDate: isAllDay ? Self.host.startOfDay(for: start) : start, endDate: end,
                                    seriesIdentifier: seriesIdentifier)
        if let occurrence = request.occurrenceDate, !request.applyToAll {
            value.matchedOccurrence = MatchedOccurrence(start: occurrence, zone: occurrenceZone)
        }
        return value
    }

    func createEventValue(_ request: EventCreateRequest) async throws -> EventCreateValue {
        creates.append(request)
        // A duplicate is an existing event: its end is five days after the request's (verify round 3).
        let isDuplicate = request.title == "duplicate"
        return EventCreateValue(
            event: EventWriteValue(eventIdentifier: isDuplicate ? "existing" : "created-\(creates.count)", title: request.title,
                                   isAllDay: request.isAllDay, startDate: request.startDate,
                                   endDate: isDuplicate ? request.endDate.addingTimeInterval(5 * 86_400) : request.endDate),
            isDuplicate: isDuplicate)
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
