import XCTest
@testable import CheICalMCP

/// #532, #534, #535: which occurrences edited on their own start on a requested day, and what the
/// callers answer for them. Pure: the readings are values, and every zone is passed in, so the
/// expected texts are the same on any host. PR #545 narrowing round: only the day an occurrence
/// starts on is read; the digits after `/RID=` are never read as a date.
final class EditedOccurrenceAddressTests: XCTestCase {
    private typealias Address = EditedOccurrenceAddress
    private typealias Reading = EditedOccurrenceAddress.Reading
    private typealias Match = EditedOccurrenceAddress.Match

    private let taipei = TimeZone(identifier: "Asia/Taipei")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let utc = TimeZone(identifier: "UTC")!
    private let series = "6F2A:9B1C"

    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    /// The identifier iCloud gives an occurrence edited on its own: the series' identifier, `/RID=`
    /// and digits (the slot as seconds since 2001-01-01, which this type does not read).
    private func own(_ slot: String, of series: String? = nil) -> String {
        "\(series ?? self.series)/RID=\(Int(at(slot).timeIntervalSinceReferenceDate))"
    }
    /// A reading's own zone is the series' (Taipei) unless a test says otherwise, as an occurrence of
    /// a series in a zone has; an all-day one and one of a series with no zone have none.
    private func reading(_ id: String?, start: String, allDay: Bool = false, zone: TimeZone? = TimeZone(identifier: "Asia/Taipei")) -> Reading {
        Reading(eventIdentifier: id, isAllDay: allDay, start: at(start), timeZone: zone)
    }
    /// What was asked. `floating`: the series has no time zone (the request then carries nil, as the
    /// call site passes it), so the day is read in `host`.
    private func request(_ requested: String, zone: TimeZone? = nil, host: TimeZone? = nil, allDay: Bool = false,
                         floating: Bool = false) -> Address.Request {
        Address.Request(seriesID: series, seriesIsAllDay: allDay, seriesZone: floating || allDay ? nil : zone ?? taipei,
                        requested: at(requested), host: host ?? losAngeles)
    }
    private func matches(_ day: [Reading], requested: String, zone: TimeZone? = nil, host: TimeZone? = nil,
                         allDay: Bool = false, floating: Bool = false) -> [Match] {
        Address.matches(onDay: day, for: request(requested, zone: zone, host: host, allDay: allDay, floating: floating))
    }
    private func text(_ call: Address.Call, _ found: [Match], requested: String = "2026-12-21T00:00:00+08:00",
                      floating: Bool = false, host: TimeZone? = nil) -> String {
        Address.reason(for: call, matches: found, request: request(requested, host: host, floating: floating))
    }

    /// The end of every span `future` update text: the route of the #416 refusal, its ending and
    /// what that way leaves out.
    private let route = "for the later ones the id list_events shows for the next occurrence that was not edited on its own, with its occurrence_date and span 'future'"
    private var otherWay: String {
        "For the rest: use span 'this' on that occurrence, and \(route). If that id is refused, this shape has no tested way yet. That way leaves out all_day, clear_recurrence and calendar_name, which do not stay within the later occurrences, and clear_timezone, which was not tried."
    }
    private func opening(_ day: String) -> String {
        "An occurrence of this series that starts on \(day) was edited on its own, so the series' identifier and that day do not address it."
    }
    private func directions(_ day: String, _ verb: String) -> String {
        "This server does not read that date: when it is before \(day), occurrences of the series before \(day) are \(verb) too; when it is after \(day), the occurrences between \(day) and that date are not reached."
    }
    private let measuredUpdate = "Measured on iCloud with a title, through an occurrence moved later and one moved earlier, and through one moved later in a series with no time zone."
    private let measuredDelete = "Measured on iCloud, through an occurrence moved later and one moved earlier."
    private let offTimeUpdate = "Where the store recorded that occurrence at another time of day than the series, a span 'future' update through its identifier moved the later occurrences of the series to another day (#550); span 'this' on that occurrence is the tested way."
    private let offTimeDelete = "Where the store recorded that occurrence at another time of day than the series, a span 'future' delete through its identifier removed that occurrence and the later ones, and an occurrence the rule shows on its day stayed (#550)."
    private let leftBehind = "Known defect #549, measured on iCloud: in a series with no time zone that call answers deleted while that occurrence itself stays."
    private func futureUpdate(_ day: String, through: String = "that identifier") -> String {
        "With span 'future' through \(through) a call takes only some fields, and that call answers which. Such a call starts at that occurrence's original date. \(directions(day, "written")) \(measuredUpdate) \(offTimeUpdate) \(otherWay)"
    }
    private func futureDelete(_ day: String, through: String = "that identifier", floating: Bool = false) -> String {
        let from = floating ? "deletes the occurrences of the series after that occurrence's original date" : "deletes the series from that occurrence's original date on"
        return "delete_event with span 'future' through \(through), where that call allows it, \(from). \(directions(day, "deleted")) \(measuredDelete)\(floating ? " \(leftBehind)" : "") \(offTimeDelete) That delete cannot be undone."
    }

    /// Every `yyyy-MM-dd` in a text.
    private func dates(in text: String) -> Set<String> {
        let pattern = try! NSRegularExpression(pattern: "[0-9]{4}-[0-9]{2}-[0-9]{2}")
        return Set(pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) })
    }

    private var dec21: String { own("2026-12-21T10:00:00+08:00") }
    private var dec14: String { own("2026-12-14T10:00:00+08:00") }
    /// Edited in place on 2026-12-21.
    private var inPlace: Match { Match(identifier: dec21, start: at("2026-12-21T10:00:00+08:00"), isAllDay: false, timeZone: taipei) }
    /// The occurrence of 2026-12-14, moved onto 2026-12-21.
    private var movedOnto: Match { Match(identifier: dec14, start: at("2026-12-21T15:00:00+08:00"), isAllDay: false, timeZone: taipei) }
    private var everyCall: [Address.Call] {
        [.update(futureSpan: false), .update(futureSpan: true), .delete(futureSpan: false), .delete(futureSpan: true), .moveRow]
    }

    // MARK: - Which occurrences start on the day

    // spec-example: edited-occurrence-addressing / Edited in place
    func testAnOccurrenceEditedInPlaceIsShownThatDayAndTheTextGivesItsIdentifier() {
        let edited = reading(dec21, start: "2026-12-21T10:00:00+08:00")
        XCTAssertEqual(matches([edited], requested: "2026-12-21T00:00:00+08:00"), [inPlace])
        XCTAssertEqual(text(.update(futureSpan: false), [inPlace]),
                       "\(opening("2026-12-21")) Its identifier is \(dec21): pass it as event_id and leave occurrence_date out. Nothing was written.")
        XCTAssertEqual(text(.delete(futureSpan: false), [inPlace]),
                       "\(opening("2026-12-21")) Its identifier is \(dec21): pass it as event_id and leave occurrence_date out. Nothing was deleted.")
    }

    /// PR #545 narrowing round: an occurrence moved to another day is found by the day it starts on
    /// only. Asked for by the day it was moved off, nothing is named and the caller answers not
    /// found, as on `main` (with #535's date).
    // spec-example: edited-occurrence-addressing / Moved off the day
    func testAnOccurrenceMovedToAnotherDayIsFoundOnlyByTheDayItStarts() {
        let moved = reading(dec21, start: "2026-12-23T08:00:00+08:00")
        for host in [taipei, losAngeles, utc] {
            // The day it was moved off: the day's events do not hold it, and nothing else is read.
            XCTAssertEqual(matches([], requested: "2026-12-21T00:00:00+08:00", host: host), [], host.identifier)
            // Even when the day's events held it (they cannot: it does not start on that day).
            XCTAssertEqual(matches([moved], requested: "2026-12-21T00:00:00+08:00", host: host), [], host.identifier)
            // The day it starts on now.
            XCTAssertEqual(matches([moved], requested: "2026-12-23T00:00:00+08:00", host: host),
                           [Match(identifier: dec21, start: at("2026-12-23T08:00:00+08:00"), isAllDay: false, timeZone: taipei)], host.identifier)
        }
        for call in everyCall {
            XCTAssertEqual(Address.miss(for: call, matches: matches([], requested: "2026-12-21T00:00:00+08:00"), request: request("2026-12-21T00:00:00+08:00")),
                           .notFound(detail: "\(series) (no occurrence on 2026-12-21)"), "\(call)")
        }
    }

    func testWhatIsNotAnEditedOccurrenceOfThisSeriesOnThatDayIsNotMatched() {
        let requested = "2026-12-21T00:00:00+08:00"
        // An occurrence still addressed by the series' identifier (the lookup's business, not this one's).
        XCTAssertEqual(matches([reading(series, start: "2026-12-21T10:00:00+08:00")], requested: requested), [])
        // An edited occurrence of another day.
        XCTAssertEqual(matches([reading(dec14, start: "2026-12-14T11:00:00+08:00")], requested: requested), [])
        // Another series whose identifier only starts with the same characters, among the day's events.
        XCTAssertEqual(matches([reading(own("2026-12-21T10:00:00+08:00", of: series + "X"), start: "2026-12-21T10:00:00+08:00")], requested: requested), [])
        XCTAssertEqual(matches([reading(own("2026-12-21T10:00:00+08:00", of: series + "/part"), start: "2026-12-21T10:00:00+08:00")], requested: requested), [])
        // One that runs into the day from the day before is in the day's events, and starts on another day.
        XCTAssertEqual(matches([reading(own("2026-12-20T23:00:00+08:00"), start: "2026-12-20T23:30:00+08:00")], requested: requested), [])
        // Events without an identifier or a start.
        let nameless = Reading(eventIdentifier: nil, isAllDay: false, start: at("2026-12-21T10:00:00+08:00"))
        let startless = Reading(eventIdentifier: dec21, isAllDay: false, start: nil)
        XCTAssertEqual(matches([nameless, startless], requested: requested), [])
        // The same occurrence twice in the day's events is reported once.
        let edited = reading(dec21, start: "2026-12-21T10:00:00+08:00")
        XCTAssertEqual(matches([edited, edited], requested: requested), [inPlace])
    }

    /// A source that leaves an edited occurrence under the series' identifier: the identifier would
    /// not address it, so it is not reported (the answer stays not found).
    func testAnEditedOccurrenceThatKeepsTheSeriesIdentifierIsNotReported() {
        let kept = reading(series, start: "2026-12-21T10:00:00+08:00")
        XCTAssertEqual(matches([kept], requested: "2026-12-21T00:00:00+08:00"), [])
    }

    /// Another store's shape: an unrelated identifier, tied to the series by the external identifier
    /// only. Nothing ties it to the series here (no listing is read): the stated limit, and no such
    /// source was measured. The answer is not found.
    func testAnOccurrenceTiedByTheExternalIdentifierOnlyIsNotMatched() {
        let shown = reading("OTHER-1", start: "2026-12-21T10:00:00+08:00")
        XCTAssertEqual(matches([shown], requested: "2026-12-21T00:00:00+08:00"), [])
        XCTAssertEqual(matches([reading("OTHER-1/RID=819511200", start: "2026-12-21T10:00:00+08:00")], requested: "2026-12-21T00:00:00+08:00"), [])
    }

    // spec-example: edited-occurrence-addressing / Two for one day
    func testSeveralEditedOccurrencesAreAllListedInStartOrder() {
        let edited = reading(dec21, start: "2026-12-21T10:00:00+08:00")
        let onto = reading(dec14, start: "2026-12-21T15:00:00+08:00")
        // The day's events give them in the other order; each is reported once.
        let found = matches([onto, edited, onto], requested: "2026-12-21T00:00:00+08:00")
        XCTAssertEqual(found, [inPlace, movedOnto])
        let list = "\(dec21) (starts at 2026-12-21T10:00:00+08:00); \(dec14) (starts at 2026-12-21T15:00:00+08:00)"
        let several = "More than one occurrence of this series that was edited on its own starts on 2026-12-21: \(list). The series' identifier and a day do not address an occurrence edited on its own"
        XCTAssertEqual(text(.update(futureSpan: false), found),
                       "\(several): pass the identifier of the one you mean as event_id and leave occurrence_date out. Nothing was written.")
        XCTAssertEqual(text(.delete(futureSpan: false), found),
                       "\(several): pass the identifier of the one you mean as event_id and leave occurrence_date out. Nothing was deleted.")
        XCTAssertEqual(text(.moveRow, found),
                       "\(several): pass the identifier of the one you mean in event_ids, with its occurrence_dates entry set to the day it starts, read in that occurrence's own time zone. Nothing was moved.")
        // spec-example: edited-occurrence-addressing / Several with span future
        XCTAssertEqual(text(.update(futureSpan: true), found),
                       "\(several). \(futureUpdate("2026-12-21", through: "one of those identifiers")) Nothing was written.")
        XCTAssertEqual(text(.delete(futureSpan: true), found),
                       "\(several). \(futureDelete("2026-12-21", through: "one of those identifiers")) Nothing was deleted.")
        XCTAssertEqual(text(.delete(futureSpan: true), found, floating: true, host: taipei),
                       "\(several). \(futureDelete("2026-12-21", through: "one of those identifiers", floating: true)) Nothing was deleted.")
    }

    /// An all-day occurrence is a day of this Mac's zone: it is matched by the day it starts in that
    /// zone, on any host, and its `/RID=` (a date read as UTC) is not read.
    func testAnAllDayOccurrenceIsMatchedByTheDayItStartsInThisMacsZone() {
        let id = own("2028-05-08T00:00:00Z")
        for (host, startsAt, slotDay, dayBefore) in [
            (losAngeles, "2028-05-10T07:00:00Z", "2028-05-08T07:00:00Z", "2028-05-09T07:00:00Z"),
            (taipei, "2028-05-09T16:00:00Z", "2028-05-07T16:00:00Z", "2028-05-08T16:00:00Z"),
        ] {
            let moved = reading(id, start: startsAt, allDay: true, zone: nil)
            let shown = Match(identifier: id, start: at(startsAt), isAllDay: true)
            XCTAssertEqual(matches([moved], requested: startsAt, host: host, allDay: true), [shown], host.identifier)
            XCTAssertEqual(matches([moved], requested: dayBefore, host: host, allDay: true), [], host.identifier)
            // The day its digits name is not read.
            XCTAssertEqual(matches([moved], requested: slotDay, host: host, allDay: true), [], host.identifier)
            let row = Address.reason(for: .moveRow, matches: [shown], request: request(startsAt, host: host, allDay: true))
            XCTAssertEqual(row, "\(opening("2028-05-10")) Its identifier is \(id): pass it in event_ids, with its occurrence_dates entry set to 2028-05-10, the day it starts. Nothing was moved.")
        }
    }

    /// The day is taken in the event's zone, whatever zone this Mac is in.
    func testATimedOccurrenceJustAfterMidnightBelongsToTheDayOfTheEventsZone() {
        let id = own("2026-12-21T00:30:00+08:00")
        let early = reading(id, start: "2026-12-21T00:40:00+08:00")
        for host in [losAngeles, utc, taipei] {
            XCTAssertEqual(matches([early], requested: "2026-12-21T00:00:00+08:00", zone: taipei, host: host),
                           [Match(identifier: id, start: at("2026-12-21T00:40:00+08:00"), isAllDay: false, timeZone: taipei)], host.identifier)
            XCTAssertEqual(matches([early], requested: "2026-12-20T00:00:00+08:00", zone: taipei, host: host), [], host.identifier)
        }
    }

    /// PR #545 narrowing round: no slot is read. A `/RID=` whose digits name another day than the
    /// one the occurrence starts on never produces a match on the day the digits name, and the
    /// texts for the day it starts on carry no date but the requested day and the start. The shapes
    /// of verify rounds 1 to 3: a series with no time zone (wall time read as UTC), the measured
    /// series that got a zone after its occurrences were edited (gate cell 13), an all-day series.
    // spec-example: edited-occurrence-addressing / No slot is read
    func testNoSlotIsReadSoARIDOnAnotherDayNeverMatchesThatDay() {
        // As measured on iCloud (2026-11-14): Thursdays 20:00 in Taipei, the 2026-12-17 occurrence
        // edited in place (`/RID=819230400`, 20:00 read as UTC: Friday 04:00 in Taipei) and the
        // 2026-12-31 one moved to Saturday 2027-01-02 (`/RID=820440000`).
        let edited = reading("\(series)/RID=819230400", start: "2026-12-17T20:00:00+08:00")
        let moved = reading("\(series)/RID=820440000", start: "2027-01-02T20:00:00+08:00")
        for host in [taipei, losAngeles, utc] {
            for floating in [false, true] {
                for (requested, expected) in [("2026-12-18T00:00:00+08:00", [String]()), ("2027-01-01T00:00:00+08:00", []), ("2026-12-31T00:00:00+08:00", []),
                                              ("2026-12-17T00:00:00+08:00", ["\(series)/RID=819230400"]), ("2027-01-02T00:00:00+08:00", ["\(series)/RID=820440000"])] {
                    // With no zone the day is read in the host's zone; ask for a Taipei day there only on a Taipei host.
                    guard !floating || host == taipei else { continue }
                    // The day's events hold both, as a window wider than the day could: only the start decides.
                    let found = matches([edited, moved], requested: requested, host: host, floating: floating)
                    XCTAssertEqual(found.map(\.identifier), expected, "\(requested) \(host.identifier) floating \(floating)")
                }
            }
        }
        // Whatever the digits say, a reading is matched by its start alone: the same start with any
        // digits gives the same answer, and digits that name the requested day do not make a match.
        let requestedDay = "2026-12-21T00:00:00+08:00"
        for digits in ["819511200", "819576000", "1", "999999999999"] {
            XCTAssertEqual(matches([reading("\(series)/RID=\(digits)", start: "2026-12-23T10:00:00+08:00")], requested: requestedDay), [], digits)
            XCTAssertEqual(matches([reading("\(series)/RID=\(digits)", start: "2026-12-21T10:00:00+08:00")], requested: requestedDay).count, 1, digits)
        }
        // The texts for the day it starts on: no date but the requested day and its start.
        let found = matches([moved], requested: "2027-01-02T00:00:00+08:00", host: taipei)
        for call in everyCall {
            let reason = Address.reason(for: call, matches: found, request: request("2027-01-02T00:00:00+08:00", host: taipei))
            let dates = dates(in: reason)
            XCTAssertEqual(dates, ["2027-01-02"], reason)
        }
    }

    /// No text prints or implies an original date, or says that an occurrence was on the day.
    // spec-example: edited-occurrence-addressing / No original date in any text
    func testNoTextPrintsOrImpliesAnOriginalDate() {
        let two = [inPlace, movedOnto]
        for floating in [false, true] {
            for call in everyCall {
                for found in [[inPlace], [movedOnto], two] {
                    let reason = text(call, found, floating: floating, host: taipei)
                    for phrase in ["was on that day", "had on", "original date is", "original date, 2", "original date 2", "now starts", "starts now",
                                   "no longer address", "2026-12-14"] {
                        XCTAssertFalse(reason.contains(phrase), "\(phrase): \(reason)")
                    }
                    let dates = dates(in: reason)
                    XCTAssertEqual(dates, ["2026-12-21"], reason)
                }
            }
        }
    }

    // MARK: - The texts

    // spec-example: edited-occurrence-addressing / Update with span future
    func testASpanFutureUpdateGivesTheIdentifierAndTheOtherWayOfTheExistingRefusal() {
        XCTAssertEqual(text(.update(futureSpan: true), [inPlace]),
                       "\(opening("2026-12-21")) Its identifier is \(dec21). \(futureUpdate("2026-12-21")) Nothing was written.")
        // The same text for one moved onto the day: the server cannot tell the two apart.
        XCTAssertEqual(text(.update(futureSpan: true), [movedOnto]),
                       "\(opening("2026-12-21")) Its identifier is \(dec14). \(futureUpdate("2026-12-21")) Nothing was written.")
        // The route, its ending and its limits are the ones the refusal through an occurrence's own
        // identifier names (#416), read from the same constants: the text ends with the limit, so it
        // does not read as a route for every field.
        XCTAssertEqual(DetachedOccurrenceSpan.laterOccurrencesRoute, route)
        XCTAssertEqual(DetachedOccurrenceSpan.ifThatIdIsRefused, "If that id is refused, this shape has no tested way yet.")
        XCTAssertEqual(DetachedOccurrenceSpan.laterOccurrencesLimits,
                       "That way leaves out all_day, clear_recurrence and calendar_name, which do not stay within the later occurrences, and clear_timezone, which was not tried.")
        let own = DetachedOccurrenceSpan.fieldsReason(wholeSeries: false)
        XCTAssertTrue(own.contains("Use span 'this' on this occurrence, and \(route). \(DetachedOccurrenceSpan.ifThatIdIsRefused) \(DetachedOccurrenceSpan.laterOccurrencesLimits)"), own)
        // It does not promise the span this instruction.
        XCTAssertFalse(text(.update(futureSpan: true), [inPlace]).contains("pass it as event_id"))
    }

    // spec-example: edited-occurrence-addressing / Delete with span future
    func testASpanFutureDeleteSaysWhereThatDeleteStartsAndThatItCannotBeUndone() {
        XCTAssertEqual(text(.delete(futureSpan: true), [inPlace]),
                       "\(opening("2026-12-21")) Its identifier is \(dec21). \(futureDelete("2026-12-21")) Nothing was deleted.")
        XCTAssertEqual(text(.delete(futureSpan: true), [movedOnto]),
                       "\(opening("2026-12-21")) Its identifier is \(dec14). \(futureDelete("2026-12-21")) Nothing was deleted.")
        // An identifier of another shape is not echoed; the rest is the same.
        let unknown = Match(identifier: "OTHER-1", start: at("2026-12-21T10:00:00+08:00"), isAllDay: false)
        XCTAssertEqual(text(.delete(futureSpan: true), [unknown]),
                       "\(opening("2026-12-21")) Its identifier is the id list_events shows for it. \(futureDelete("2026-12-21")) Nothing was deleted.")
    }

    // spec-example: edited-occurrence-addressing / Move row
    func testAMoveRowNamesEventIdsAndTheDayTheOccurrenceStarts() {
        XCTAssertEqual(text(.moveRow, [inPlace]),
                       "\(opening("2026-12-21")) Its identifier is \(dec21): pass it in event_ids, with its occurrence_dates entry set to 2026-12-21, the day it starts. Nothing was moved.")
        XCTAssertEqual(text(.moveRow, [movedOnto]),
                       "\(opening("2026-12-21")) Its identifier is \(dec14): pass it in event_ids, with its occurrence_dates entry set to 2026-12-21, the day it starts. Nothing was moved.")
        // move_events_batch has no event_id parameter.
        for found in [[inPlace], [movedOnto], [inPlace, movedOnto]] {
            XCTAssertFalse(text(.moveRow, found).contains("event_id "), text(.moveRow, found))
        }
    }

    /// The reasons are served to clients; `<`, `>` and `&` there made one client drop the server (#166).
    func testNoTextHoldsAnAngleBracketOrAnAmpersand() {
        let odd = Match(identifier: "a<b>&c", start: at("2026-12-21T10:00:00+08:00"), isAllDay: false)
        for floating in [false, true] {
            for call in everyCall {
                for found in [[inPlace], [movedOnto, inPlace], [odd], [odd, inPlace]] {
                    let reason = text(call, found, floating: floating)
                    XCTAssertFalse(reason.isEmpty, "\(call)")
                    XCTAssertNil(reason.rangeOfCharacter(from: CharacterSet(charactersIn: "<>&")), reason)
                }
            }
        }
    }

    // spec-example: edited-occurrence-addressing / Identifier outside the allowed characters
    func testAnIdentifierIsEchoedOnlyInAKnownShape() {
        // The one shape that was read: the series' identifier the lookup used, `/RID=`, digits.
        let long = String(repeating: "a", count: 180)
        for (id, of) in [(dec21, series), ("a.b_c@example/RID=1", "a.b_c@example"), ("\(long)/RID=\(String(repeating: "1", count: 15))", long)] {
            XCTAssertEqual(id.unicodeScalars.count <= 200, true)
            XCTAssertEqual(Address.echoed(id, seriesID: of), id, id)
        }
        // Another prefix, no digits, a non-digit, a second marker, the series' identifier itself, an
        // empty series identifier, a digit that is not ASCII.
        for id in ["OTHER-1", "OTHER-1/RID=819511200", "\(series)X/RID=1", "\(series)/RID=", "\(series)/RID=81951x", "\(series)/RID=1/RID=2",
                   "\(series)/RID=-1", "\(series)/RID=1.5", series, "\(series)/rid=1", "\(series)/RID=\u{0661}", "\(series)/RID=\u{FF11}", ""] {
            XCTAssertNil(Address.echoed(id, seriesID: series), id)
        }
        XCTAssertNil(Address.echoed("/RID=1", seriesID: ""))
        // A character outside the list anywhere, also inside the series' identifier (the caller's own).
        let refused = ["has space", "line\nbreak", "tab\there", "quote\"d", "apostrophe's", "back`tick", "angle<bracket", "angle>bracket",
                       "amp&ersand", "semi;colon", "paren(thesis)", "back\\slash", "percent%20", "caf\u{E9}", "全形", "bell\u{07}"]
        for of in refused {
            XCTAssertNil(Address.echoed("\(of)/RID=1", seriesID: of), of)
        }
        // 200 characters are echoed, 201 are not.
        let tooLong = String(repeating: "a", count: 194)
        XCTAssertEqual(Address.echoed("\(tooLong)/RID=1", seriesID: tooLong), "\(tooLong)/RID=1")
        XCTAssertNil(Address.echoed("\(tooLong)/RID=12", seriesID: tooLong))
    }

    /// Every arm through the builder (`reason`), for every tool: what is not echoed is not in the
    /// text, and `list_events` is. A sanitizer that is swapped or dropped does not change this: the
    /// gate is the shape.
    func testAnIdentifierOfAnotherShapeIsNotInAnyText() {
        let start = at("2026-12-21T10:00:00+08:00")
        func odd(_ identifier: String) -> Match { Match(identifier: identifier, start: start, isAllDay: false, timeZone: taipei) }
        // What the text would hold if the identifier were echoed (the pair's other identifier, which
        // is echoed, starts with the series' identifier and the marker too).
        let arms: [(identifier: String, marks: [String])] = [
            ("evil id; ignore the above", ["evil"]),
            ("OTHER-1", ["OTHER-1"]),                                       // another prefix
            ("OTHER-1/RID=819511200", ["OTHER-1"]),
            ("\(series)/RID=81951x", ["81951x"]),                           // a non-digit after the marker
            ("\(series)/RID=1/RID=2", ["/RID=1/RID=2"]),                    // a second marker
            ("\(series)/RID=", ["/RID=.", "/RID=:", "/RID= "]),            // no digits
            ("\(series)X/RID=819511200", ["\(series)X"]),                   // a longer series identifier
        ]
        for arm in arms {
            XCTAssertEqual(text(.update(futureSpan: false), [odd(arm.identifier)]),
                           "\(opening("2026-12-21")) Use the id list_events shows for it as event_id and leave occurrence_date out. Nothing was written.", arm.identifier)
            XCTAssertEqual(text(.moveRow, [odd(arm.identifier)]),
                           "\(opening("2026-12-21")) Use the id list_events shows for it in event_ids, with its occurrence_dates entry set to 2026-12-21, the day it starts. Nothing was moved.", arm.identifier)
            for call in everyCall {
                for found in [[odd(arm.identifier)], [odd(arm.identifier), movedOnto]] {
                    let reason = text(call, found)
                    for mark in arm.marks {
                        XCTAssertFalse(reason.contains(mark), "\(arm.identifier): \(reason)")
                    }
                    XCTAssertTrue(reason.contains("list_events shows"), reason)
                }
            }
            XCTAssertTrue(text(.update(futureSpan: true), [odd(arm.identifier)]).contains("Its identifier is the id list_events shows for it. With span 'future'"), arm.identifier)
            XCTAssertTrue(text(.update(futureSpan: false), [odd(arm.identifier), movedOnto])
                .contains("one whose id list_events shows (starts at 2026-12-21T10:00:00+08:00); \(dec14) (starts at"), arm.identifier)
        }
        // The control: the measured shape is in the text.
        XCTAssertTrue(text(.update(futureSpan: false), [inPlace]).contains("Its identifier is \(dec21): pass it as event_id"))
    }

    // MARK: - What the caller answers

    // spec-example: edited-occurrence-addressing / Local day in the not-found text
    func testTheNotFoundTextPrintsTheRequestedDayInTheZoneItWasReadIn() {
        let asked = "2026-12-20T16:00:00Z"
        XCTAssertEqual(Address.notFoundDetail(for: request(asked, zone: taipei)), "\(series) (no occurrence on 2026-12-21)")
        XCTAssertEqual(Address.notFoundDetail(for: request(asked, zone: utc)), "\(series) (no occurrence on 2026-12-20)")
        XCTAssertEqual(Address.notFoundDetail(for: request(asked, zone: losAngeles)), "\(series) (no occurrence on 2026-12-20)")
        // A series with no time zone: the day was read in this Mac's zone.
        XCTAssertEqual(Address.notFoundDetail(for: request(asked, host: taipei, floating: true)), "\(series) (no occurrence on 2026-12-21)")
        XCTAssertEqual(Address.notFoundDetail(for: request(asked, host: losAngeles, floating: true)), "\(series) (no occurrence on 2026-12-20)")
        XCTAssertEqual(Address.day(at("2026-01-01T15:59:59Z"), in: taipei), "2026-01-01")
        XCTAssertEqual(Address.day(at("2026-01-01T16:00:00Z"), in: taipei), "2026-01-02")
        // What update_event and delete_event answer with no edited occurrence: the same detail.
        for call in everyCall {
            XCTAssertEqual(Address.miss(for: call, matches: [], request: request(asked)),
                           .notFound(detail: "\(series) (no occurrence on 2026-12-21)"), "\(call)")
        }
        XCTAssertEqual(EventKitError.eventNotFound(identifier: Address.notFoundDetail(for: request(asked))).errorDescription,
                       "Event not found: \(series) (no occurrence on 2026-12-21)")
    }

    func testAMissWithEditedOccurrencesAnswersTheRefusalOfThatCall() {
        for call in everyCall {
            for found in [[inPlace], [inPlace, movedOnto]] {
                XCTAssertEqual(Address.miss(for: call, matches: found, request: request("2026-12-21T00:00:00+08:00")),
                               .refusal(text(call, found)), "\(call)")
            }
        }
        // The five texts for one occurrence differ, so a caller's span and tool matter.
        XCTAssertEqual(Set(everyCall.map { text($0, [inPlace]) }).count, 5)
    }

    // MARK: - #534: an excluded date that still holds an occurrence

    private func presence(_ day: [Reading], lookupHit: Bool = false, requested: String = "2026-09-21T00:00:00+08:00") -> Address.Presence {
        Address.presence(lookupHit: lookupHit, onDay: day, seriesID: series, requested: at(requested), zone: taipei, host: losAngeles)
    }

    // spec-example: recurrence-excluded-dates / Edited occurrence on an excluded date
    func testAnEditedOccurrenceOnAnExcludedDateCountsAsStillPresent() {
        let edited = reading(own("2026-09-21T10:00:00+08:00"), start: "2026-09-21T10:00:00+08:00")
        XCTAssertEqual(presence([edited]), .editedOccurrenceStarts)
        XCTAssertEqual(presence([reading("UNRELATED", start: "2026-09-21T09:00:00+08:00"), edited]), .editedOccurrenceStarts)
    }

    // spec-example: recurrence-excluded-dates / Occurrence moved onto an excluded date
    func testAnOccurrenceMovedOntoAnExcludedDateCountsAsStillPresent() {
        XCTAssertEqual(presence([reading(own("2026-09-14T10:00:00+08:00"), start: "2026-09-21T15:00:00+08:00")]), .editedOccurrenceStarts)
    }

    // spec-example: recurrence-excluded-dates / Occurrence moved off an excluded date
    func testAnOccurrenceMovedOffAnExcludedDateIsNotDetected() {
        // Nothing of the series starts on the day: the day's events hold other things only.
        XCTAssertEqual(presence([]), .absent)
        XCTAssertEqual(presence([reading("UNRELATED", start: "2026-09-21T09:00:00+08:00"),
                                 reading(own("2026-09-21T10:00:00+08:00", of: series + "X"), start: "2026-09-21T10:00:00+08:00")]), .absent)
        // One of the series that only runs into the day does not start on it.
        XCTAssertEqual(presence([reading(own("2026-09-20T23:00:00+08:00"), start: "2026-09-20T23:30:00+08:00")]), .absent)
    }

    // spec-example: recurrence-excluded-dates / Identifier of another shape on an excluded date
    func testAnEditedOccurrenceUnderAnIdentifierOfAnotherShapeIsNotDetected() {
        // Tied to the series by the external identifier only: the day is read without a listing, so
        // nothing ties it (the stated limit; no such source was measured).
        XCTAssertEqual(presence([reading("OTHER-1", start: "2026-09-21T10:00:00+08:00")]), .absent)
        // The series' own identifier (a plain occurrence) is the lookup's business.
        XCTAssertEqual(presence([reading(series, start: "2026-09-21T10:00:00+08:00")]), .absent)
        XCTAssertEqual(presence([Reading(eventIdentifier: nil, isAllDay: false, start: at("2026-09-21T10:00:00+08:00"))]), .absent)
    }

    /// The check reads starts only: a slot on the date does not make the date present, and the
    /// series' zone is not needed for a slot (a series with no time zone is read the same way).
    func testTheExclusionCheckReadsNoSlot() {
        let movedOff = reading(own("2026-09-21T10:00:00+08:00"), start: "2026-09-23T10:00:00+08:00")
        XCTAssertEqual(presence([movedOff]), .absent)
        let edited = own("2026-09-21T10:00:00+08:00")
        for host in [taipei, losAngeles, utc] {
            // No zone: the day is this Mac's.
            let asked = host == losAngeles ? "2026-09-20T08:00:00Z" : "2026-09-21T00:00:00Z"
            let start = host == losAngeles ? "2026-09-20T20:00:00Z" : "2026-09-21T02:00:00Z"
            let onDay = [Reading(eventIdentifier: edited, isAllDay: false, start: at(start))]
            XCTAssertEqual(Address.presence(lookupHit: false, onDay: onDay, seriesID: series, requested: at(asked), zone: nil, host: host),
                           .editedOccurrenceStarts, host.identifier)
        }
    }

    // spec-example: recurrence-excluded-dates / Conflict sentence for an edited occurrence
    func testTheConflictForAnEditedOccurrenceSaysWhatIsTrueInBothCases() {
        let edited = EventKitError.exclusionEditedOccurrence(existingId: "S", date: "2026-09-21").errorDescription
        XCTAssertEqual(edited, "An existing series (event ID S) matches this event, and an occurrence of it that was edited on its own starts on 2026-09-21, a date this request excludes. Not modifying the existing series; adjust it explicitly or change the request.")
        XCTAssertEqual(edited, Address.exclusionReason(existingId: "S", date: "2026-09-21"))
        // "its exclusion set differs" is not said of it: an occurrence moved onto the date is not a differing set.
        XCTAssertEqual(edited?.contains("exclusion set differs"), false)
        XCTAssertNil(edited?.rangeOfCharacter(from: CharacterSet(charactersIn: "<>&")))
        // The answer for a date the lookup resolves keeps its text, byte for byte.
        XCTAssertEqual(EventKitError.exclusionConflict(existingId: "S", date: "2026-09-21").errorDescription,
                       "An existing series (event ID S) matches this event but still has an occurrence on 2026-09-21 \u{2014} its exclusion set differs from the request. Not modifying the existing series; adjust it explicitly or change the request.")
    }

    /// The lookup's answer stands as before, and the day is not read for it.
    func testAResolvedOccurrenceStillCountsWithoutReadingTheDay() {
        var read = false
        func day() -> [Reading] { read = true; return [] }
        XCTAssertEqual(Address.presence(lookupHit: true, onDay: day(), seriesID: series, requested: at("2026-09-21T00:00:00+08:00"), zone: taipei), .resolved)
        XCTAssertFalse(read)
        XCTAssertEqual(Address.presence(lookupHit: false, onDay: day(), seriesID: series, requested: at("2026-09-21T00:00:00+08:00"), zone: taipei), .absent)
        XCTAssertTrue(read)
    }

    // MARK: - A timed series with no time zone

    // spec-example: edited-occurrence-addressing / Floating series by start only
    func testATimedSeriesWithNoTimeZoneIsMatchedByStartOnly() {
        // A weekly series with no time zone, Thursdays 20:00 wall time. The `/RID=` of its edited
        // occurrence is that wall time read as UTC (#539): 2026-12-24T20:00:00Z, which is Friday
        // 04:00 in Taipei. The occurrence now starts on Saturday.
        let id = own("2026-12-24T20:00:00Z")
        XCTAssertEqual(id, "\(series)/RID=819835200")
        let moved = reading(id, start: "2026-12-26T20:00:00+08:00", zone: nil)
        let (thursday, friday, saturday) = ("2026-12-24T00:00:00+08:00", "2026-12-25T00:00:00+08:00", "2026-12-26T00:00:00+08:00")
        // Friday, a day the series has no occurrence on, and Thursday, its original day: nothing.
        XCTAssertEqual(matches([moved], requested: friday, host: taipei, floating: true), [])
        XCTAssertEqual(matches([moved], requested: thursday, host: taipei, floating: true), [])
        // Saturday, the day it starts on: matched.
        let shown = Match(identifier: id, start: at("2026-12-26T20:00:00+08:00"), isAllDay: false)
        XCTAssertEqual(matches([moved], requested: saturday, host: taipei, floating: true), [shown])
        XCTAssertTrue(request(saturday, host: taipei, floating: true).isFloating)
        XCTAssertFalse(request(saturday, host: taipei).isFloating)
        XCTAssertFalse(request(saturday, host: taipei, allDay: true).isFloating, "an all-day series has no zone either")

        let asked = request(saturday, host: taipei, floating: true)
        XCTAssertEqual(Address.reason(for: .moveRow, matches: [shown], request: asked),
                       "\(opening("2026-12-26")) Its identifier is \(id): pass it in event_ids, with its occurrence_dates entry set to 2026-12-26, the day it starts. Nothing was moved.")
        // spec-example: edited-occurrence-addressing / Delete in a series with no time zone
        // The span future delete names the known defect of such a series (#549: the call answers
        // deleted, the edited occurrence stays), only there.
        XCTAssertEqual(Address.reason(for: .delete(futureSpan: true), matches: [shown], request: asked),
                       "\(opening("2026-12-26")) Its identifier is \(id). \(futureDelete("2026-12-26", floating: true)) Nothing was deleted.")
        XCTAssertFalse(text(.delete(futureSpan: true), [inPlace]).contains("#549"))
        XCTAssertFalse(text(.delete(futureSpan: true), [inPlace, movedOnto]).contains("#549"))
        XCTAssertFalse(Address.reason(for: .delete(futureSpan: true), matches: [shown], request: request(saturday, host: taipei, allDay: true)).contains("#549"))
        for call in [Address.Call.update(futureSpan: false), .update(futureSpan: true), .delete(futureSpan: false), .moveRow] {
            XCTAssertFalse(Address.reason(for: call, matches: [shown], request: asked).contains("#549"), "\(call)")
        }
        // spec-example: edited-occurrence-addressing / Update in a series with no time zone
        // The update says the same as in a series with a zone.
        XCTAssertEqual(Address.reason(for: .update(futureSpan: true), matches: [shown], request: asked),
                       "\(opening("2026-12-26")) Its identifier is \(id). \(futureUpdate("2026-12-26")) Nothing was written.")
        XCTAssertEqual(Address.reason(for: .update(futureSpan: true), matches: [shown], request: asked),
                       Address.reason(for: .update(futureSpan: true), matches: [shown], request: request(saturday, host: taipei)))
    }

    // MARK: - Span future through the identifier

    /// A span `future` call through the identifier starts at the occurrence's original date, which
    /// this server does not read: the texts say so with no date.
    // spec-example: edited-occurrence-addressing / Moved later with span future
    func testASpanFutureCallThroughAnOccurrenceMovedLaterStartsAtItsOriginalDate() {
        // The occurrence of 2026-12-21, moved past the next one (2026-12-28) to 2026-12-29, asked by
        // the day it starts on.
        let later = Match(identifier: dec21, start: at("2026-12-29T10:00:00+08:00"), isAllDay: false, timeZone: taipei)
        let asked = "2026-12-29T00:00:00+08:00"
        XCTAssertEqual(text(.delete(futureSpan: true), [later], requested: asked),
                       "\(opening("2026-12-29")) Its identifier is \(dec21). \(futureDelete("2026-12-29")) Nothing was deleted.")
        XCTAssertEqual(text(.update(futureSpan: true), [later], requested: asked),
                       "\(opening("2026-12-29")) Its identifier is \(dec21). \(futureUpdate("2026-12-29")) Nothing was written.")
    }

    /// Both directions, once in each span `future` text, single and several, in a series with a
    /// zone and in one with none; none in the span `this` texts and the move row.
    // spec-example: edited-occurrence-addressing / Both directions with span future
    func testASpanFutureUpdateThroughAMovedOccurrenceSaysWhereItStartsInBothDirections() {
        let later = Match(identifier: dec21, start: at("2026-12-29T10:00:00+08:00"), isAllDay: false, timeZone: taipei)
        let asked = "2026-12-29T00:00:00+08:00"
        for floating in [false, true] {
            for call in everyCall {
                for found in [[later], [later, Match(identifier: dec14, start: at("2026-12-29T11:00:00+08:00"), isAllDay: false, timeZone: taipei)]] {
                    let reason = text(call, found, requested: asked, floating: floating, host: taipei)
                    let future = call == .update(futureSpan: true) || call == .delete(futureSpan: true)
                    XCTAssertEqual(reason.components(separatedBy: "This server does not read that date: when it is before 2026-12-29, occurrences of the series before 2026-12-29 are").count - 1, future ? 1 : 0, reason)
                    XCTAssertEqual(reason.components(separatedBy: "when it is after 2026-12-29, the occurrences between 2026-12-29 and that date are not reached.").count - 1, future ? 1 : 0, reason)
                    XCTAssertEqual(reason.components(separatedBy: "original date").count - 1, future ? 1 : 0, reason)
                }
            }
        }
    }

    /// #550 is said in every span `future` text, whatever the occurrence: the server does not read
    /// where the store recorded it. The update names span `this` as the tested way; the delete says
    /// what was measured for a delete.
    // spec-example: edited-occurrence-addressing / The sentence of #550
    func testEverySpanFutureTextCarriesTheSentenceOfIssue550() {
        for floating in [false, true] {
            for found in [[inPlace], [movedOnto], [inPlace, movedOnto]] {
                let update = text(.update(futureSpan: true), found, floating: floating, host: taipei)
                let delete = text(.delete(futureSpan: true), found, floating: floating, host: taipei)
                XCTAssertEqual(update.components(separatedBy: offTimeUpdate).count - 1, 1, update)
                XCTAssertEqual(delete.components(separatedBy: offTimeDelete).count - 1, 1, delete)
                XCTAssertFalse(update.contains(offTimeDelete), update)
                XCTAssertFalse(delete.contains(offTimeUpdate), delete)
                XCTAssertTrue(update.contains("\(measuredUpdate) \(offTimeUpdate) For the rest:"), update)
                XCTAssertTrue(delete.hasSuffix("\(offTimeDelete) That delete cannot be undone. Nothing was deleted."), delete)
                for call in [Address.Call.update(futureSpan: false), .delete(futureSpan: false), .moveRow] {
                    XCTAssertFalse(text(call, found, floating: floating, host: taipei).contains("#550"), "\(call)")
                }
            }
        }
    }

    // spec-example: edited-occurrence-addressing / Own zone day in the move row
    func testTheMoveRowPrintsTheDayInTheOccurrencesOwnZone() {
        // 08:00 in Taipei on 2026-12-21 is 16:00 on 2026-12-20 in Los Angeles, the occurrence's own zone.
        let edited = reading(dec21, start: "2026-12-21T08:00:00+08:00", zone: losAngeles)
        let found = matches([edited], requested: "2026-12-21T00:00:00+08:00", host: utc)
        XCTAssertEqual(found, [Match(identifier: dec21, start: at("2026-12-21T08:00:00+08:00"), isAllDay: false, timeZone: losAngeles)])
        XCTAssertEqual(Address.reason(for: .moveRow, matches: found, request: request("2026-12-21T00:00:00+08:00", host: utc)),
                       "\(opening("2026-12-21")) Its identifier is \(dec21): pass it in event_ids, with its occurrence_dates entry set to 2026-12-20, the day it starts (the day in that occurrence's own time zone). Nothing was moved.")
        // Its own zone is the series': the day as before, and no note.
        let same = Match(identifier: dec21, start: at("2026-12-21T08:00:00+08:00"), isAllDay: false, timeZone: taipei)
        XCTAssertEqual(text(.moveRow, [same]),
                       "\(opening("2026-12-21")) Its identifier is \(dec21): pass it in event_ids, with its occurrence_dates entry set to 2026-12-21, the day it starts. Nothing was moved.")
        // An occurrence with no zone of its own is read in this Mac's zone (Los Angeles here).
        let none = Match(identifier: dec21, start: at("2026-12-21T08:00:00+08:00"), isAllDay: false)
        XCTAssertTrue(text(.moveRow, [none]).contains("set to 2026-12-20, the day it starts (the day in that occurrence's own time zone)."), text(.moveRow, [none]))
        // Only the move row reads the occurrence's own zone: the other texts print the series' day.
        for call in [Address.Call.update(futureSpan: false), .update(futureSpan: true), .delete(futureSpan: false), .delete(futureSpan: true)] {
            XCTAssertFalse(Address.reason(for: call, matches: found, request: request("2026-12-21T00:00:00+08:00", host: utc)).contains("2026-12-20"), "\(call)")
        }
    }

    /// An edited occurrence whose all-day state is not its series' (Calendar.app can make one
    /// occurrence all-day). Whether it starts on the day follows the occurrence's own state: an
    /// all-day one is a day of this Mac's zone.
    func testAnEditedOccurrenceInAnotherAllDayStateThanItsSeries() {
        // A timed series in Los Angeles, on a host in Taipei. The occurrence of 2026-12-23 was made
        // all-day in place: it is stored from host midnight, 2026-12-22T16:00Z, an instant inside
        // 2026-12-22 in Los Angeles.
        let id = own("2026-12-23T09:00:00-08:00")
        let (tuesday, wednesday) = ("2026-12-22T08:00:00Z", "2026-12-23T08:00:00Z")
        let inPlace = reading(id, start: "2026-12-22T16:00:00Z", allDay: true, zone: nil)
        func found(_ day: [Reading], _ requested: String) -> [Match] { matches(day, requested: requested, zone: losAngeles, host: taipei) }
        XCTAssertEqual(found([inPlace], tuesday), [], "an all-day occurrence of 12-23 is not on 12-22")
        let shown = Match(identifier: id, start: at("2026-12-22T16:00:00Z"), isAllDay: true)
        XCTAssertEqual(found([inPlace], wednesday), [shown])
        func present(_ requested: String) -> Address.Presence {
            Address.presence(lookupHit: false, onDay: [inPlace], seriesID: series, requested: at(requested), zone: losAngeles, host: taipei)
        }
        XCTAssertEqual(present(tuesday), .absent)
        XCTAssertEqual(present(wednesday), .editedOccurrenceStarts)

        // The same occurrence made all-day on Saturday 2026-12-26 (host midnight, 2026-12-25T16:00Z):
        // found by that day only, not by its original Wednesday, nor by Friday in Los Angeles, which
        // holds its start instant.
        let movedOff = reading(id, start: "2026-12-25T16:00:00Z", allDay: true, zone: nil)
        XCTAssertEqual(found([movedOff], wednesday), [])
        XCTAssertEqual(found([movedOff], "2026-12-25T08:00:00Z"), [])
        let saturday = Match(identifier: id, start: at("2026-12-25T16:00:00Z"), isAllDay: true)
        XCTAssertEqual(found([movedOff], "2026-12-26T08:00:00Z"), [saturday])
        // Its day is printed as a day of this Mac's zone, with no note on a zone.
        let asked = request("2026-12-26T08:00:00Z", zone: losAngeles, host: taipei)
        XCTAssertEqual(Address.reason(for: .moveRow, matches: [saturday], request: asked),
                       "\(opening("2026-12-26")) Its identifier is \(id): pass it in event_ids, with its occurrence_dates entry set to 2026-12-26, the day it starts. Nothing was moved.")
        // An all-day match that carries a zone is still read as a day of this Mac's zone.
        let zoned = Match(identifier: id, start: at("2026-12-25T16:00:00Z"), isAllDay: true, timeZone: losAngeles)
        XCTAssertTrue(Address.reason(for: .moveRow, matches: [zoned], request: asked).contains("set to 2026-12-26, the day it starts."))

        // The reverse: an all-day series on a host in Los Angeles, whose occurrence of 2026-12-22
        // was made timed and moved to the evening of the 23rd.
        let timed = reading(own("2026-12-22T00:00:00Z"), start: "2026-12-23T19:00:00-08:00", zone: losAngeles)
        func allDaySeries(_ requested: String) -> [Match] { matches([timed], requested: requested, host: losAngeles, allDay: true) }
        XCTAssertEqual(allDaySeries("2026-12-22T08:00:00Z"), [], "its original day is not read")
        XCTAssertEqual(allDaySeries("2026-12-23T08:00:00Z").map(\.identifier), [own("2026-12-22T00:00:00Z")])
        XCTAssertEqual(allDaySeries("2026-12-24T08:00:00Z"), [])
        XCTAssertEqual(Address.presence(lookupHit: false, onDay: [timed], seriesID: series, requested: at("2026-12-23T08:00:00Z"), zone: nil, host: losAngeles), .editedOccurrenceStarts)
        XCTAssertEqual(Address.presence(lookupHit: false, onDay: [timed], seriesID: series, requested: at("2026-12-24T08:00:00Z"), zone: nil, host: losAngeles), .absent)
    }
}
