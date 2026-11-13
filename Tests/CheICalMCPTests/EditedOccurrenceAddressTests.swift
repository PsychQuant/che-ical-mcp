import XCTest
@testable import CheICalMCP

/// #532, #534, #535: which occurrences edited on their own belong to a requested day, and what the
/// callers answer for them. Pure: the readings are values, and every zone is passed in, so the
/// expected texts are the same on any host.
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
    /// and the slot as seconds since 2001-01-01.
    private func own(_ slot: String, of series: String? = nil) -> String {
        "\(series ?? self.series)/RID=\(Int(at(slot).timeIntervalSinceReferenceDate))"
    }
    private func reading(_ id: String?, start: String, detached: Bool = true, allDay: Bool = false,
                         external: String? = nil, occurrenceDate: Date? = nil) -> Reading {
        Reading(eventIdentifier: id, externalIdentifier: external, occurrenceDate: occurrenceDate,
                isDetached: detached, isAllDay: allDay, start: at(start))
    }
    private func matches(day: [Reading], listed: [Reading]?, requested: String, zone: TimeZone? = nil,
                         host: TimeZone? = nil, allDay: Bool = false) -> [Match] {
        Address.matches(onDay: day, listed: listed, seriesID: series, seriesIsAllDay: allDay,
                        requested: at(requested), zone: zone ?? taipei, host: host ?? losAngeles)
    }
    private func text(_ call: Address.Call, _ found: [Match], requested: String = "2026-12-21T00:00:00+08:00") -> String {
        Address.reason(for: call, matches: found, requested: at(requested), zone: taipei, host: losAngeles)
    }

    private var dec21: String { own("2026-12-21T10:00:00+08:00") }
    private var dec14: String { own("2026-12-14T10:00:00+08:00") }
    private var inPlace: Match {
        Match(identifier: dec21, start: at("2026-12-21T10:00:00+08:00"), isAllDay: false, kind: .shownThatDay, originalDay: "2026-12-21")
    }
    private var movedOff: Match {
        Match(identifier: dec21, start: at("2026-12-23T08:00:00+08:00"), isAllDay: false, kind: .originallyThatDay, originalDay: "2026-12-21")
    }
    private var movedOnto: Match {
        Match(identifier: dec14, start: at("2026-12-21T15:00:00+08:00"), isAllDay: false, kind: .shownThatDay, originalDay: "2026-12-14")
    }
    private let opening = "The occurrence of this series on 2026-12-21 was edited on its own, so the series' identifier and that day no longer address it."
    private let movedOpening = "The occurrence this series had on 2026-12-21 was edited on its own and now starts at 2026-12-23T08:00:00+08:00, so the series' identifier and that day no longer address it."

    // MARK: - Which occurrences belong to the day

    // spec-example: edited-occurrence-addressing / Edited in place
    func testAnOccurrenceEditedInPlaceIsShownThatDayAndTheTextGivesItsIdentifier() {
        let edited = reading(dec21, start: "2026-12-21T10:00:00+08:00")
        for listed in [[edited], nil] as [[Reading]?] {
            XCTAssertEqual(matches(day: [edited], listed: listed, requested: "2026-12-21T00:00:00+08:00"), [inPlace])
        }
        XCTAssertEqual(text(.update(futureSpan: false), [inPlace]),
                       "\(opening) Its identifier is \(dec21): pass it as event_id and leave occurrence_date out. Nothing was written.")
        XCTAssertEqual(text(.delete(futureSpan: false), [inPlace]),
                       "\(opening) Its identifier is \(dec21): pass it as event_id and leave occurrence_date out. Nothing was deleted.")
    }

    // spec-example: edited-occurrence-addressing / Moved off the day
    func testAnOccurrenceMovedToAnotherDayIsFoundByItsOriginalDayAndByTheDayItStarts() {
        let moved = reading(dec21, start: "2026-12-23T08:00:00+08:00")
        // The original day: the day's events do not hold it, the series listing does.
        XCTAssertEqual(matches(day: [], listed: [moved], requested: "2026-12-21T00:00:00+08:00"), [movedOff])
        // The day it starts now: found by the day alone, and once when the listing holds it too.
        let shown = Match(identifier: dec21, start: at("2026-12-23T08:00:00+08:00"), isAllDay: false, kind: .shownThatDay, originalDay: "2026-12-21")
        XCTAssertEqual(matches(day: [moved], listed: nil, requested: "2026-12-23T00:00:00+08:00"), [shown])
        XCTAssertEqual(matches(day: [moved], listed: [moved], requested: "2026-12-23T00:00:00+08:00"), [shown])
        // A day that is neither.
        XCTAssertEqual(matches(day: [], listed: [moved], requested: "2026-12-22T00:00:00+08:00"), [])
        XCTAssertEqual(text(.update(futureSpan: false), [movedOff]),
                       "\(movedOpening) Its identifier is \(dec21): pass it as event_id and leave occurrence_date out. Nothing was written.")
        XCTAssertEqual(text(.delete(futureSpan: false), [movedOff]),
                       "\(movedOpening) Its identifier is \(dec21): pass it as event_id and leave occurrence_date out. Nothing was deleted.")
    }

    func testWhatIsNotAnEditedOccurrenceOfThisSeriesOnThatDayIsNotMatched() {
        let requested = "2026-12-21T00:00:00+08:00"
        // An occurrence still addressed by the series' identifier (the lookup's business, not this one's).
        let plain = reading(series, start: "2026-12-21T10:00:00+08:00", detached: false)
        XCTAssertEqual(matches(day: [plain], listed: [plain], requested: requested), [])
        // An edited occurrence of another day, by start and by slot.
        let otherDay = reading(dec14, start: "2026-12-14T11:00:00+08:00")
        XCTAssertEqual(matches(day: [], listed: [otherDay], requested: requested), [])
        // Another series whose identifier only starts with the same characters, among the day's events.
        let longer = reading(own("2026-12-21T10:00:00+08:00", of: series + "X"), start: "2026-12-21T10:00:00+08:00")
        XCTAssertEqual(matches(day: [longer], listed: nil, requested: requested), [])
        let nested = reading(own("2026-12-21T10:00:00+08:00", of: series + "/part"), start: "2026-12-21T10:00:00+08:00")
        XCTAssertEqual(matches(day: [nested], listed: nil, requested: requested), [])
        // One that runs into the day from the day before is in the day's events, and starts on another day.
        let overnight = reading(own("2026-12-20T23:00:00+08:00"), start: "2026-12-20T23:30:00+08:00")
        XCTAssertEqual(matches(day: [overnight], listed: nil, requested: requested), [])
        // Events without an identifier or a start.
        let nameless = Reading(eventIdentifier: nil, externalIdentifier: nil, occurrenceDate: nil, isDetached: true, isAllDay: false,
                               start: at("2026-12-21T10:00:00+08:00"))
        let startless = Reading(eventIdentifier: dec21, externalIdentifier: nil, occurrenceDate: nil, isDetached: true, isAllDay: false, start: nil)
        XCTAssertEqual(matches(day: [nameless, startless], listed: [nameless, startless], requested: requested), [])
    }

    /// A source that leaves an edited occurrence under the series' identifier: the identifier would
    /// not address it, so it is not reported (the answer stays not found).
    func testAnEditedOccurrenceThatKeepsTheSeriesIdentifierIsNotReported() {
        let slot = at("2026-12-21T10:00:00+08:00")
        let kept = reading(series, start: "2026-12-23T08:00:00+08:00", occurrenceDate: slot)
        XCTAssertEqual(matches(day: [], listed: [kept], requested: "2026-12-21T00:00:00+08:00"), [])
    }

    /// Another store's shape: an unrelated identifier, tied to the series by the external identifier
    /// only. The listing ties it (`seriesOccurrences`); the day's events cannot.
    func testAnOccurrenceTiedByTheExternalIdentifierOnlyIsMatchedFromTheListing() {
        let external = "UID-1/RID=\(Int(at("2026-12-21T10:00:00+08:00").timeIntervalSinceReferenceDate))"
        let shown = reading("OTHER-1", start: "2026-12-21T10:00:00+08:00", external: external)
        XCTAssertEqual(matches(day: [shown], listed: [shown], requested: "2026-12-21T00:00:00+08:00"),
                       [Match(identifier: "OTHER-1", start: at("2026-12-21T10:00:00+08:00"), isAllDay: false, kind: .shownThatDay, originalDay: "2026-12-21")])
        XCTAssertEqual(matches(day: [shown], listed: nil, requested: "2026-12-21T00:00:00+08:00"), [], "without the listing nothing ties it")
        let moved = reading("OTHER-1", start: "2026-12-23T08:00:00+08:00", external: external)
        XCTAssertEqual(matches(day: [], listed: [moved], requested: "2026-12-21T00:00:00+08:00"),
                       [Match(identifier: "OTHER-1", start: at("2026-12-23T08:00:00+08:00"), isAllDay: false, kind: .originallyThatDay, originalDay: "2026-12-21")])
    }

    // spec-example: edited-occurrence-addressing / Two for one day
    func testSeveralEditedOccurrencesAreAllListedInStartOrder() {
        let off = reading(dec21, start: "2026-12-23T08:00:00+08:00")
        let onto = reading(dec14, start: "2026-12-21T15:00:00+08:00")
        // The listing gives them in the other order; each is reported once.
        let found = matches(day: [onto], listed: [off, onto], requested: "2026-12-21T00:00:00+08:00")
        XCTAssertEqual(found, [movedOnto, movedOff])
        let list = "\(dec14) (starts at 2026-12-21T15:00:00+08:00); \(dec21) (was on that day, now starts at 2026-12-23T08:00:00+08:00)"
        let several = "More than one occurrence of this series that was edited on its own belongs to 2026-12-21: \(list). The series' identifier and a day do not address an occurrence edited on its own"
        XCTAssertEqual(text(.update(futureSpan: false), found),
                       "\(several): pass the identifier of the one you mean as event_id and leave occurrence_date out. Nothing was written.")
        XCTAssertEqual(text(.delete(futureSpan: false), found),
                       "\(several): pass the identifier of the one you mean as event_id and leave occurrence_date out. Nothing was deleted.")
        XCTAssertEqual(text(.moveRow, found),
                       "\(several): pass the identifier of the one you mean in event_ids, with its occurrence_dates entry set to the day it starts now. Nothing was moved.")
        // With span future the one moved onto the day says where it came from, as the cut follows it.
        let futureList = "\(dec14) (starts at 2026-12-21T15:00:00+08:00, original date 2026-12-14); \(dec21) (was on that day, now starts at 2026-12-23T08:00:00+08:00)"
        let futureSeveral = "More than one occurrence of this series that was edited on its own belongs to 2026-12-21: \(futureList). The series' identifier and a day do not address an occurrence edited on its own"
        XCTAssertEqual(text(.update(futureSpan: true), found),
                       "\(futureSeveral). With span 'future' through one of those identifiers a call takes only some fields, and that call answers which. For the rest: use span 'this' on that occurrence, and \(DetachedOccurrenceSpan.laterOccurrencesRoute). Nothing was written.")
        XCTAssertEqual(text(.delete(futureSpan: true), found),
                       "\(futureSeveral). delete_event with span 'future' through one of those identifiers deletes the series from that occurrence's original date on, where that call allows it, and that delete cannot be undone. Nothing was deleted.")
    }

    /// The `/RID=` of an all-day occurrence is its date read as UTC, while the occurrence and the
    /// requested day are days of this Mac's zone. Read as an instant, a host west of UTC puts the
    /// slot on the day before.
    func testAnAllDayOccurrenceIsReadByTheDateInItsIdentifierOnAnyHost() {
        let id = own("2028-05-08T00:00:00Z")
        for (host, startsAt, requestedSlotDay, dayBefore) in [
            (losAngeles, "2028-05-10T07:00:00Z", "2028-05-08T07:00:00Z", "2028-05-07T07:00:00Z"),
            (taipei, "2028-05-09T16:00:00Z", "2028-05-07T16:00:00Z", "2028-05-06T16:00:00Z"),
        ] {
            let moved = reading(id, start: startsAt, allDay: true)
            let expected = Match(identifier: id, start: at(startsAt), isAllDay: true, kind: .originallyThatDay, originalDay: "2028-05-08")
            XCTAssertEqual(matches(day: [], listed: [moved], requested: requestedSlotDay, zone: host, host: host, allDay: true), [expected],
                           host.identifier)
            XCTAssertEqual(matches(day: [], listed: [moved], requested: dayBefore, zone: host, host: host, allDay: true), [], host.identifier)
            // The day it starts now, 2028-05-10 in the host's zone.
            let shown = Match(identifier: id, start: at(startsAt), isAllDay: true, kind: .shownThatDay, originalDay: "2028-05-08")
            XCTAssertEqual(matches(day: [moved], listed: nil, requested: startsAt, zone: host, host: host, allDay: true), [shown], host.identifier)
            // Its start and its day are printed in the host's zone.
            let row = Address.reason(for: .moveRow, matches: [expected], requested: at(requestedSlotDay), zone: host, host: host)
            XCTAssertTrue(row.contains("with its occurrence_dates entry set to 2028-05-10, the day it starts now."), row)
            XCTAssertTrue(row.hasPrefix("The occurrence this series had on 2028-05-08 was edited on its own and now starts at 2028-05-10T00:00:00"), row)
        }
    }

    /// The day is taken in the event's zone, whatever zone this Mac is in.
    func testATimedOccurrenceJustAfterMidnightBelongsToTheDayOfTheEventsZone() {
        let id = own("2026-12-21T00:30:00+08:00")
        let early = reading(id, start: "2026-12-21T00:40:00+08:00")
        for host in [losAngeles, utc, taipei] {
            let found = matches(day: [early], listed: [early], requested: "2026-12-21T00:00:00+08:00", zone: taipei, host: host)
            XCTAssertEqual(found, [Match(identifier: id, start: at("2026-12-21T00:40:00+08:00"), isAllDay: false, kind: .shownThatDay, originalDay: "2026-12-21")],
                           host.identifier)
            XCTAssertEqual(matches(day: [early], listed: [early], requested: "2026-12-20T00:00:00+08:00", zone: taipei, host: host), [], host.identifier)
        }
    }

    // spec-example: edited-occurrence-addressing / Series that cannot be listed
    func testWithoutAListingOnlyWhatStartsOnTheDayIsFound() {
        let moved = reading(dec21, start: "2026-12-23T08:00:00+08:00")
        // Moved off the day and no listing: nothing is named (the caller answers not found).
        XCTAssertEqual(matches(day: [], listed: nil, requested: "2026-12-21T00:00:00+08:00"), [])
        XCTAssertEqual(matches(day: [moved], listed: nil, requested: "2026-12-21T00:00:00+08:00"), [])
        // One shown on the day needs no listing.
        let edited = reading(dec21, start: "2026-12-21T10:00:00+08:00")
        XCTAssertEqual(matches(day: [edited], listed: nil, requested: "2026-12-21T00:00:00+08:00"), [inPlace])
    }

    // MARK: - The texts

    // spec-example: edited-occurrence-addressing / Update with span future
    func testASpanFutureUpdateGivesTheIdentifierAndTheOtherWayOfTheExistingRefusal() {
        let route = "for the later ones the id list_events shows for the next occurrence that was not edited on its own, with its occurrence_date and span 'future'"
        let rest = "With span 'future' through that identifier a call takes only some fields, and that call answers which. For the rest: use span 'this' on that occurrence, and \(route). Nothing was written."
        XCTAssertEqual(text(.update(futureSpan: true), [inPlace]), "\(opening) Its identifier is \(dec21). \(rest)")
        XCTAssertEqual(text(.update(futureSpan: true), [movedOff]),
                       "The occurrence this series had on 2026-12-21 was edited on its own and now starts at 2026-12-23T08:00:00+08:00 (its original date is 2026-12-21), so the series' identifier and that day no longer address it. Its identifier is \(dec21). \(rest)")
        XCTAssertEqual(text(.update(futureSpan: true), [movedOnto]),
                       "The occurrence of this series on 2026-12-21 was edited on its own (its original date is 2026-12-14), so the series' identifier and that day no longer address it. Its identifier is \(dec14). \(rest)")
        // The route is the one the refusal through an occurrence's own identifier names (#416).
        XCTAssertEqual(DetachedOccurrenceSpan.laterOccurrencesRoute, route)
        XCTAssertTrue(DetachedOccurrenceSpan.fieldsReason(wholeSeries: false).contains("Use span 'this' on this occurrence, and \(route). If that id is refused, this shape has no tested way yet."))
        // It does not promise the span this instruction.
        XCTAssertFalse(text(.update(futureSpan: true), [inPlace]).contains("pass it as event_id"))
    }

    // spec-example: edited-occurrence-addressing / Delete with span future
    func testASpanFutureDeleteSaysWhereThatDeleteStartsAndThatItCannotBeUndone() {
        let rest = "delete_event with span 'future' through that identifier deletes the series from that occurrence's original date, 2026-12-21, on, where that call allows it, and that delete cannot be undone. Nothing was deleted."
        XCTAssertEqual(text(.delete(futureSpan: true), [inPlace]), "\(opening) Its identifier is \(dec21). \(rest)")
        XCTAssertEqual(text(.delete(futureSpan: true), [movedOff]),
                       "The occurrence this series had on 2026-12-21 was edited on its own and now starts at 2026-12-23T08:00:00+08:00 (its original date is 2026-12-21), so the series' identifier and that day no longer address it. Its identifier is \(dec21). \(rest)")
        // Moved onto the requested day: the delete starts at the day it came from, not the requested one.
        XCTAssertEqual(text(.delete(futureSpan: true), [movedOnto]),
                       "The occurrence of this series on 2026-12-21 was edited on its own (its original date is 2026-12-14), so the series' identifier and that day no longer address it. Its identifier is \(dec14). delete_event with span 'future' through that identifier deletes the series from that occurrence's original date, 2026-12-14, on, where that call allows it, and that delete cannot be undone. Nothing was deleted.")
        // With no slot known, no date is named.
        let unknown = Match(identifier: "OTHER-1", start: at("2026-12-21T10:00:00+08:00"), isAllDay: false, kind: .shownThatDay, originalDay: nil)
        XCTAssertEqual(text(.delete(futureSpan: true), [unknown]),
                       "\(opening) Its identifier is OTHER-1. delete_event with span 'future' through that identifier deletes the series from that occurrence's original date on, where that call allows it, and that delete cannot be undone. Nothing was deleted.")
    }

    // spec-example: edited-occurrence-addressing / Move row
    func testAMoveRowNamesEventIdsAndTheDayTheOccurrenceStarts() {
        XCTAssertEqual(text(.moveRow, [movedOff]),
                       "\(movedOpening) Its identifier is \(dec21): pass it in event_ids, with its occurrence_dates entry set to 2026-12-23, the day it starts now. Nothing was moved.")
        XCTAssertEqual(text(.moveRow, [inPlace]),
                       "\(opening) Its identifier is \(dec21): pass it in event_ids, with its occurrence_dates entry set to 2026-12-21, the day it starts. Nothing was moved.")
        XCTAssertEqual(text(.moveRow, [movedOnto]),
                       "\(opening) Its identifier is \(dec14): pass it in event_ids, with its occurrence_dates entry set to 2026-12-21, the day it starts now. Nothing was moved.")
        // move_events_batch has no event_id parameter.
        for found in [[movedOff], [inPlace], [movedOnto, movedOff]] {
            XCTAssertFalse(text(.moveRow, found).contains("event_id "), text(.moveRow, found))
        }
    }

    private var everyCall: [Address.Call] {
        [.update(futureSpan: false), .update(futureSpan: true), .delete(futureSpan: false), .delete(futureSpan: true), .moveRow]
    }

    /// The reasons are served to clients; `<`, `>` and `&` there made one client drop the server (#166).
    func testNoTextHoldsAnAngleBracketOrAnAmpersand() {
        let odd = Match(identifier: "a<b>&c", start: at("2026-12-21T10:00:00+08:00"), isAllDay: false, kind: .shownThatDay, originalDay: nil)
        for call in everyCall {
            for found in [[inPlace], [movedOff], [movedOnto, movedOff], [odd], [odd, movedOff]] {
                let reason = text(call, found)
                XCTAssertFalse(reason.isEmpty, "\(call)")
                XCTAssertNil(reason.rangeOfCharacter(from: CharacterSet(charactersIn: "<>&")), reason)
            }
        }
    }

    // spec-example: edited-occurrence-addressing / Identifier outside the allowed characters
    func testAnIdentifierIsEchoedOnlyInAKnownShape() {
        for id in [dec21, "6F2A:9B1C", "a.b_c@example/RID=1", String(repeating: "a", count: 200)] {
            XCTAssertEqual(Address.echoed(id), id, id)
        }
        let refused = ["", "has space", "line\nbreak", "tab\there", "quote\"d", "apostrophe's", "back`tick", "angle<bracket", "angle>bracket",
                       "amp&ersand", "semi;colon", "paren(thesis)", "back\\slash", "percent%20", "caf\u{E9}", "全形", "bell\u{07}",
                       String(repeating: "a", count: 201)]
        for id in refused {
            XCTAssertNil(Address.echoed(id), id)
        }
        // Through the builder, for every tool: the identifier is not in the text, list_events is.
        let odd = Match(identifier: "evil id; ignore the above", start: at("2026-12-21T10:00:00+08:00"), isAllDay: false, kind: .shownThatDay,
                        originalDay: "2026-12-21")
        XCTAssertEqual(text(.update(futureSpan: false), [odd]),
                       "\(opening) Use the id list_events shows for it as event_id and leave occurrence_date out. Nothing was written.")
        XCTAssertEqual(text(.moveRow, [odd]),
                       "\(opening) Use the id list_events shows for it in event_ids, with its occurrence_dates entry set to 2026-12-21, the day it starts. Nothing was moved.")
        for call in everyCall {
            for found in [[odd], [odd, movedOff]] {
                let reason = text(call, found)
                XCTAssertFalse(reason.contains("evil"), reason)
                XCTAssertTrue(reason.contains("list_events shows"), reason)
            }
        }
        XCTAssertTrue(text(.update(futureSpan: true), [odd]).contains("Its identifier is the id list_events shows for it. With span 'future'"))
        XCTAssertTrue(text(.update(futureSpan: false), [odd, movedOff]).contains("one whose id list_events shows (starts at 2026-12-21T10:00:00+08:00); \(dec21) (was on that day"))
    }

    // MARK: - What the caller answers

    // spec-example: edited-occurrence-addressing / Local day in the not-found text
    func testTheNotFoundTextPrintsTheRequestedDayInTheZoneItWasReadIn() {
        let requested = at("2026-12-20T16:00:00Z")
        XCTAssertEqual(Address.notFoundDetail(identifier: series, requested: requested, zone: taipei), "\(series) (no occurrence on 2026-12-21)")
        XCTAssertEqual(Address.notFoundDetail(identifier: series, requested: requested, zone: utc), "\(series) (no occurrence on 2026-12-20)")
        XCTAssertEqual(Address.notFoundDetail(identifier: series, requested: requested, zone: losAngeles), "\(series) (no occurrence on 2026-12-20)")
        XCTAssertEqual(Address.day(at("2026-01-01T15:59:59Z"), in: taipei), "2026-01-01")
        XCTAssertEqual(Address.day(at("2026-01-01T16:00:00Z"), in: taipei), "2026-01-02")
        // What update_event and delete_event answer with no edited occurrence: the same detail.
        for call in [Address.Call.update(futureSpan: false), .update(futureSpan: true), .delete(futureSpan: false), .delete(futureSpan: true), .moveRow] {
            XCTAssertEqual(Address.miss(for: call, matches: [], identifier: series, requested: requested, zone: taipei, host: losAngeles),
                           .notFound(detail: "\(series) (no occurrence on 2026-12-21)"), "\(call)")
        }
        XCTAssertEqual(EventKitError.eventNotFound(identifier: Address.notFoundDetail(identifier: series, requested: requested, zone: taipei)).errorDescription,
                       "Event not found: \(series) (no occurrence on 2026-12-21)")
    }

    func testAMissWithEditedOccurrencesAnswersTheRefusalOfThatCall() {
        let requested = at("2026-12-21T00:00:00+08:00")
        for call in everyCall {
            for found in [[inPlace], [movedOnto, movedOff]] {
                XCTAssertEqual(Address.miss(for: call, matches: found, identifier: series, requested: requested, zone: taipei, host: losAngeles),
                               .refusal(text(call, found)), "\(call)")
            }
        }
        // The five texts for one occurrence differ, so a caller's span and tool matter.
        XCTAssertEqual(Set(everyCall.map { text($0, [inPlace]) }).count, 5)
    }

    // MARK: - #534: an excluded date that still holds an occurrence

    private func stillPresent(_ day: [Reading], lookupHit: Bool = false, requested: String = "2026-09-21T00:00:00+08:00") -> Bool {
        Address.stillPresent(lookupHit: lookupHit, onDay: day, seriesID: series, requested: at(requested), zone: taipei, host: losAngeles)
    }

    // spec-example: recurrence-excluded-dates / Edited occurrence on an excluded date
    func testAnEditedOccurrenceOnAnExcludedDateCountsAsStillPresent() {
        let edited = reading(own("2026-09-21T10:00:00+08:00"), start: "2026-09-21T10:00:00+08:00")
        XCTAssertTrue(stillPresent([edited]))
        XCTAssertTrue(stillPresent([reading("UNRELATED", start: "2026-09-21T09:00:00+08:00", detached: false), edited]))
    }

    // spec-example: recurrence-excluded-dates / Occurrence moved onto an excluded date
    func testAnOccurrenceMovedOntoAnExcludedDateCountsAsStillPresent() {
        XCTAssertTrue(stillPresent([reading(own("2026-09-14T10:00:00+08:00"), start: "2026-09-21T15:00:00+08:00")]))
    }

    // spec-example: recurrence-excluded-dates / Occurrence moved off an excluded date
    func testAnOccurrenceMovedOffAnExcludedDateIsNotDetected() {
        // Nothing of the series starts on the day: the day's events hold other things only.
        XCTAssertFalse(stillPresent([]))
        XCTAssertFalse(stillPresent([reading("UNRELATED", start: "2026-09-21T09:00:00+08:00", detached: false),
                                     reading(own("2026-09-21T10:00:00+08:00", of: series + "X"), start: "2026-09-21T10:00:00+08:00")]))
        // One of the series that only runs into the day does not start on it.
        XCTAssertFalse(stillPresent([reading(own("2026-09-20T23:00:00+08:00"), start: "2026-09-20T23:30:00+08:00")]))
    }

    /// The lookup's answer stands as before, and the day is not read for it.
    func testAResolvedOccurrenceStillCountsWithoutReadingTheDay() {
        var read = false
        func day() -> [Reading] { read = true; return [] }
        XCTAssertTrue(Address.stillPresent(lookupHit: true, onDay: day(), seriesID: series, requested: at("2026-09-21T00:00:00+08:00"), zone: taipei))
        XCTAssertFalse(read)
        XCTAssertFalse(Address.stillPresent(lookupHit: false, onDay: day(), seriesID: series, requested: at("2026-09-21T00:00:00+08:00"), zone: taipei))
        XCTAssertTrue(read)
    }
}
