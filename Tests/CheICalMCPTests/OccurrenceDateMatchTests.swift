import XCTest
@testable import CheICalMCP

/// #543: `occurrence_date` passed with an occurrence's own identifier names the day the occurrence
/// starts on or its original day, read from its `/RID=`. Every zone is a parameter, so these answer
/// the same in every process zone (`TZ`).
final class OccurrenceDateMatchTests: XCTestCase {
    private static let utc = TimeZone(identifier: "UTC")!
    private static let taipei = TimeZone(identifier: "Asia/Taipei")!
    private static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private static func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, in zone: TimeZone) -> Date {
        Calendar.gregorian(in: zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    /// `<series id>/RID=<seconds since 2001-01-01>`, as iCloud writes an occurrence edited on its own.
    private static func identifier(rid: Date) -> String {
        "SERIES-543/RID=\(Int(rid.timeIntervalSinceReferenceDate))"
    }

    private static func answer(_ requested: Date, start: Date, startIsAllDay: Bool, zone: TimeZone?, rid: Date?,
                               externalRID: Date? = nil, occurrenceDate: Date? = nil,
                               host: TimeZone) -> OccurrenceDateMatch.Answer {
        OccurrenceDateMatch.answer(requested: requested, start: start, startIsAllDay: startIsAllDay, zone: zone,
                                   eventIdentifier: rid.map(identifier(rid:)) ?? "PLAIN-ID",
                                   externalIdentifier: externalRID.map(identifier(rid:)),
                                   occurrenceDate: occurrenceDate ?? start, host: host)
    }

    // spec-example: occurrence-date-own-identifier / one shape on five host zones
    func testAnAllDayOccurrenceAcceptsItsOriginalDayOnlyWhenBothReadingsAgree() {
        // An all-day weekly series: the occurrence of 2026-12-28 (its /RID= the floating date, 00:00 UTC)
        // was moved on its own to 2026-12-30.
        let rid = Self.day(2026, 12, 28, in: Self.utc)
        for name in ["Pacific/Pago_Pago", "America/Los_Angeles", "UTC", "Asia/Taipei", "Pacific/Kiritimati"] {
            let host = TimeZone(identifier: name)!
            let westOfUTC = host.secondsFromGMT(for: rid) < 0
            let expected: [Int: OccurrenceDateMatch.Answer] = [
                27: westOfUTC ? .undetermined : .differs, 28: westOfUTC ? .undetermined : .matches,
                29: .differs, 30: .matches
            ]
            for (requestedDay, answer) in expected.sorted(by: { $0.key < $1.key }) {
                XCTAssertEqual(Self.answer(Self.day(2026, 12, requestedDay, in: host), start: Self.day(2026, 12, 30, in: host),
                                           startIsAllDay: true, zone: nil, rid: rid, host: host),
                               answer, "host \(name), occurrence_date 2026-12-\(requestedDay)")
            }
        }
    }

    // spec-example: occurrence-date-own-identifier / Only the external identifier carries a recurrence ID
    /// V4: the external identifier can supply the /RID=. The original day is accepted where both
    /// readings agree, east of UTC and at UTC in this fixture.
    func testTheExternalIdentifiersRIDTakesOnlyTheDayBothReadingsGive() {
        let rid = Self.day(2026, 12, 28, in: Self.utc)
        func answer(_ requestedDay: Int, host: TimeZone) -> OccurrenceDateMatch.Answer {
            Self.answer(Self.day(2026, 12, requestedDay, in: host), start: Self.day(2026, 12, 30, in: host), startIsAllDay: true,
                        zone: nil, rid: nil, externalRID: rid, host: host)
        }
        XCTAssertEqual(answer(28, host: Self.taipei), .matches)
        XCTAssertEqual(answer(27, host: Self.taipei), .differs)
        XCTAssertEqual(answer(28, host: Self.utc), .matches)
        // West of UTC the instant reading gives the 27th and the date reading the 28th.
        XCTAssertEqual(answer(28, host: Self.losAngeles), .undetermined)
        XCTAssertEqual(answer(27, host: Self.losAngeles), .undetermined)
        XCTAssertEqual(answer(26, host: Self.losAngeles), .differs)
        XCTAssertEqual(answer(30, host: Self.losAngeles), .matches, "the day it shows")
    }

    // spec-example: occurrence-date-own-identifier / A timed series' occurrence made all-day on its own
    /// V1, V3: a /RID= that is not 00:00 UTC is compared as an instant with either occurrence flag.
    func testANonMidnightRIDIsComparedAsAnInstantWithEitherOccurrenceFlag() {
        // Slot 2026-12-28 07:00 Taipei is 2026-12-27 23:00 UTC. Read as a UTC date it would be the 27th.
        let host = Self.taipei
        let rid = Self.day(2026, 12, 28, hour: 7, in: host)
        for startIsAllDay in [true, false] {
            func answer(_ requestedDay: Int) -> OccurrenceDateMatch.Answer {
                Self.answer(Self.day(2026, 12, requestedDay, in: host),
                            start: Self.day(2026, 12, 30, hour: startIsAllDay ? 0 : 7, in: host), startIsAllDay: startIsAllDay,
                            zone: startIsAllDay ? nil : host, rid: rid, host: host)
            }
            let label = "occurrence all-day \(startIsAllDay)"
            XCTAssertEqual(answer(28), .matches, label)
            XCTAssertEqual(answer(27), .differs, label)
            XCTAssertEqual(answer(30), .matches, "the day it shows, \(label)")
        }
    }

    /// X2: for an instant reading the comparison is `main`'s, with the occurrence's own flag and zone.
    /// An all-day occurrence with a zone that is not the host's (V14): `main` took the slot's day in
    /// the host and the requested day in that zone.
    func testAnInstantSlotOfAnAllDayOccurrenceIsComparedAsMainComparedIt() {
        let host = Self.taipei
        let zone = Self.losAngeles
        let rid = Self.day(2026, 12, 28, hour: 7, in: host)   // 2026-12-27 23:00 UTC
        func answer(_ requestedDay: Int) -> OccurrenceDateMatch.Answer {
            Self.answer(Self.day(2026, 12, requestedDay, in: zone), start: Self.day(2026, 12, 30, in: host), startIsAllDay: true,
                        zone: zone, rid: rid, host: host)
        }
        XCTAssertEqual(answer(28), .matches)
        XCTAssertEqual(answer(27), .differs, "compared as timed in the occurrence's zone it would be the 27th")
    }

    /// An all-day series' occurrence made timed on its own: its /RID= is 00:00 UTC, and the flags of now
    /// cannot tell a floating date written by an all-day series from an instant written by a timed one
    /// converted to all-day afterwards. West of UTC the two readings give different days: undetermined.
    func testAnAllDaySeriesOccurrenceMadeTimedTakesOnlyWhatBothReadingsGive() {
        let rid = Self.day(2026, 12, 28, in: Self.utc)
        func answer(_ requestedDay: Int, host: TimeZone) -> OccurrenceDateMatch.Answer {
            Self.answer(Self.day(2026, 12, requestedDay, in: host), start: Self.day(2026, 12, 30, hour: 10, in: host),
                        startIsAllDay: false, zone: host, rid: rid, host: host)
        }
        XCTAssertEqual(answer(28, host: Self.losAngeles), .undetermined)
        XCTAssertEqual(answer(27, host: Self.losAngeles), .undetermined)
        XCTAssertEqual(answer(29, host: Self.losAngeles), .differs)
        XCTAssertEqual(answer(30, host: Self.losAngeles), .matches, "the day it shows")
        XCTAssertEqual(answer(28, host: Self.taipei), .matches)
        XCTAssertEqual(answer(27, host: Self.taipei), .differs)
    }

    /// The same shape in an occurrence zone far from the host (host UTC+14, occurrence UTC−11): the
    /// instant 2026-12-28 00:00 UTC is the 27th in the occurrence's zone.
    func testTheInstantReadingIsComparedInTheOccurrencesZone() {
        let host = TimeZone(identifier: "Pacific/Kiritimati")!
        let zone = TimeZone(identifier: "Pacific/Pago_Pago")!
        let rid = Self.day(2026, 12, 28, in: Self.utc)
        func answer(_ requestedDay: Int) -> OccurrenceDateMatch.Answer {
            Self.answer(Self.day(2026, 12, requestedDay, in: zone), start: Self.day(2026, 12, 30, hour: 10, in: zone),
                        startIsAllDay: false, zone: zone, rid: rid, host: host)
        }
        XCTAssertEqual(answer(28), .undetermined)
        XCTAssertEqual(answer(27), .undetermined)
        XCTAssertEqual(answer(26), .differs)
        XCTAssertEqual(answer(30), .matches, "the day it shows")
    }

    // spec-example: occurrence-date-own-identifier / A host that skipped the day
    /// Apia skipped December 30. The all-day comparison needs instant equality for that date.
    /// The timed comparison in UTC can agree on the civil day without instant equality.
    func testAFloatingDateIsFoundOnADayTheHostSkipped() {
        let host = TimeZone(identifier: "Pacific/Apia")!
        let rid = Self.day(2011, 12, 30, in: Self.utc)
        // An all-day occurrence with a zone of its own (V14), moved to 2012-01-02.
        func allDay(_ requestedDay: Int, hour: Int = 0) -> OccurrenceDateMatch.Answer {
            Self.answer(Self.day(2011, 12, requestedDay, hour: hour, in: Self.utc), start: Self.day(2012, 1, 2, in: host), startIsAllDay: true,
                        zone: Self.utc, rid: rid, host: host)
        }
        XCTAssertEqual(allDay(29), .undetermined)
        XCTAssertEqual(allDay(30), .matches, "the request equals the recurrence instant")
        XCTAssertEqual(allDay(30, hour: 9), .undetermined, "the instant's Apia day was the 29th")
        XCTAssertEqual(allDay(31), .differs)
        // Made timed in UTC on its own: both readings give the 30th there.
        func timed(_ requestedDay: Int) -> OccurrenceDateMatch.Answer {
            Self.answer(Self.day(2011, 12, requestedDay, hour: 9, in: Self.utc), start: Self.day(2012, 1, 2, hour: 10, in: Self.utc),
                        startIsAllDay: false, zone: Self.utc, rid: rid, host: host)
        }
        XCTAssertEqual(timed(30), .matches)
        XCTAssertEqual(timed(31), .differs)
    }

    // spec-example: occurrence-date-own-identifier / A moved timed occurrence with wall-clock digits at midnight
    func testAMovedFloatingTimedOccurrenceRefusesBothMidnightCandidates() {
        let host = Self.losAngeles
        let rid = Self.day(2026, 12, 28, in: Self.utc)
        let start = Self.day(2026, 12, 30, hour: 10, in: host)
        for requestedDay in [27, 28] {
            let answer = Self.answer(Self.day(2026, 12, requestedDay, in: host), start: start,
                                     startIsAllDay: false, zone: nil, rid: rid, host: host)
            XCTAssertEqual(answer, .undetermined, "candidate 2026-12-\(requestedDay)")
            let reason = DetachedOccurrenceSpan.occurrenceDateReason(
                for: answer, start: start, startIsAllDay: false, zone: nil, host: host)
            XCTAssertTrue(reason.contains("The recurrence ID does not establish its original day here."), reason)
        }
    }

    func testTheShownDayTakesPrecedenceWhenTheOriginalDayIsUndetermined() {
        let host = Self.losAngeles
        let rid = Self.day(2026, 12, 28, in: Self.utc)
        for shownDay in [27, 28] {
            let requested = Self.day(2026, 12, shownDay, hour: 9, in: host)
            let start = Self.day(2026, 12, shownDay, in: host)
            XCTAssertEqual(Self.answer(requested, start: start, startIsAllDay: true, zone: nil, rid: rid, host: host),
                           .matches, "shown day 2026-12-\(shownDay)")
        }
    }

    /// A timed occurrence of a timed series, as on `main`: the /RID= is the slot's instant.
    func testATimedOccurrenceIsReadAsBefore() {
        let zone = Self.losAngeles
        let host = Self.taipei
        let rid = Self.day(2026, 12, 28, hour: 9, in: zone)
        func answer(_ requestedDay: Int) -> OccurrenceDateMatch.Answer {
            Self.answer(Self.day(2026, 12, requestedDay, in: zone), start: Self.day(2026, 12, 30, hour: 9, in: zone),
                        startIsAllDay: false, zone: zone, rid: rid, host: host)
        }
        XCTAssertEqual(answer(28), .matches)
        XCTAssertEqual(answer(30), .matches)
        XCTAssertEqual(answer(27), .differs)
        XCTAssertEqual(answer(29), .differs)
    }

    /// Without a /RID=, the original slot is `occurrenceDate`, already a day of the host for an all-day occurrence.
    func testWithoutRIDTheOccurrenceDateIsTheOriginalDay() {
        let host = Self.losAngeles
        let slot = Self.day(2026, 12, 28, in: host)
        func answer(_ requestedDay: Int) -> OccurrenceDateMatch.Answer {
            Self.answer(Self.day(2026, 12, requestedDay, in: host), start: Self.day(2026, 12, 30, in: host), startIsAllDay: true,
                        zone: nil, rid: nil, occurrenceDate: slot, host: host)
        }
        XCTAssertEqual(answer(28), .matches)
        XCTAssertEqual(answer(30), .matches)
        XCTAssertEqual(answer(27), .differs)
    }

    func testTheMidnightUTCBoundary() {
        let midnight = Self.day(2026, 12, 28, in: Self.utc)
        XCTAssertTrue(OccurrenceDateMatch.isWholeUTCDay(midnight))
        XCTAssertTrue(OccurrenceDateMatch.isWholeUTCDay(Self.day(1999, 12, 31, in: Self.utc)), "before the reference date")
        XCTAssertFalse(OccurrenceDateMatch.isWholeUTCDay(midnight.addingTimeInterval(-1)))
        XCTAssertFalse(OccurrenceDateMatch.isWholeUTCDay(midnight.addingTimeInterval(1)))
    }

    /// The refusal of an undetermined date says why and how to name the occurrence; a date that is
    /// not the occurrence keeps the reason of #416.
    func testTheRefusalOfAnUndeterminedDateNamesTheShownDay() {
        let start = Self.day(2026, 12, 30, in: Self.losAngeles)
        let answer = Self.answer(Self.day(2026, 12, 28, in: Self.losAngeles), start: start,
                                 startIsAllDay: true, zone: nil, rid: nil,
                                 externalRID: Self.day(2026, 12, 28, in: Self.utc), host: Self.losAngeles)
        let reason = DetachedOccurrenceSpan.occurrenceDateReason(
            for: answer, start: start, startIsAllDay: true, zone: nil, host: Self.losAngeles)
        XCTAssertTrue(reason.contains("The recurrence ID does not establish its original day here."), reason)
        XCTAssertFalse(reason.contains("/RID="), reason)
        XCTAssertFalse(reason.contains("is a date or an instant"), reason)
        XCTAssertTrue(reason.contains("Pass 2026-12-30 as occurrence_date"), reason)
        XCTAssertTrue(reason.contains("or leave occurrence_date out"), reason)
        XCTAssertFalse(reason.contains("as list_events shows it"), reason)
        XCTAssertTrue(reason.hasSuffix("Nothing was changed."), reason)
        XCTAssertFalse(reason.contains("series' identifier"), reason)
        for answer in [OccurrenceDateMatch.Answer.differs, .matches] {
            XCTAssertEqual(DetachedOccurrenceSpan.occurrenceDateReason(
                for: answer, start: start, startIsAllDay: true, zone: nil, host: Self.losAngeles),
                DetachedOccurrenceSpan.occurrenceDateReason)
        }
    }

    func testTheUndeterminedRefusalUsesTheSameZoneAsTheShownStartCheck() {
        let start = Self.day(2026, 12, 30, in: Self.taipei)
        let allDay = DetachedOccurrenceSpan.occurrenceDateReason(
            for: .undetermined, start: start, startIsAllDay: true, zone: Self.losAngeles, host: Self.taipei)
        let timed = DetachedOccurrenceSpan.occurrenceDateReason(
            for: .undetermined, start: start, startIsAllDay: false, zone: Self.losAngeles, host: Self.taipei)
        let floating = DetachedOccurrenceSpan.occurrenceDateReason(
            for: .undetermined, start: start, startIsAllDay: false, zone: nil, host: Self.taipei)
        XCTAssertTrue(allDay.contains("Pass 2026-12-30 as occurrence_date"), allDay)
        XCTAssertTrue(timed.contains("Pass 2026-12-29 as occurrence_date"), timed)
        XCTAssertTrue(floating.contains("Pass 2026-12-30 as occurrence_date"), floating)
    }

    func testTheUndeterminedRefusalOffersOmissionWhenThereIsNoStart() {
        let reason = DetachedOccurrenceSpan.occurrenceDateReason(
            for: .undetermined, start: nil, startIsAllDay: true, zone: nil, host: Self.losAngeles)
        XCTAssertTrue(reason.contains("Leave occurrence_date out to act on this occurrence."), reason)
    }
}
