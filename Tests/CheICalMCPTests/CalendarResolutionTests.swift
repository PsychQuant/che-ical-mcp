import XCTest
@testable import CheICalMCP

/// #604: how a call finds the one calendar it acts on, from a title, a source and a calendar `id`.
/// Everything here runs on a fake item type; no test reads or writes the live EventKit store.
final class CalendarResolutionTests: XCTestCase {
    private struct Cal: Equatable {
        let id: String
        let title: String
        var source = "iCloud"
    }

    private func resolve(_ all: [Cal], name: String? = nil, source: String? = nil, id: String? = nil)
        -> CalendarLookup.Outcome<Cal> {
        CalendarLookup.resolve(all, name: name, source: source, id: id,
                               identifier: \.id, title: \.title, sourceTitle: \.source)
    }

    private let pairOne = Cal(id: "A1B2-C3", title: "Calendar A")
    private let pairTwo = Cal(id: "D4E5-F6", title: "Calendar A")
    private let work = Cal(id: "W1", title: "Work")
    private let googlePair = Cal(id: "G1", title: "Calendar A", source: "Google")

    // MARK: spec-example: calendar-resolution / two calendars in one account are refused

    func testTwoCalendarsOfOneTitleInOneAccountAreAmbiguous() {
        guard case .ambiguousInAccount(let found) = resolve([pairOne, pairTwo, work], name: "Calendar A", source: "iCloud") else {
            return XCTFail("two same-title calendars of one account must be ambiguous")
        }
        XCTAssertEqual(found, [pairOne, pairTwo])
    }

    func testAnAmbiguousPairIsAmbiguousWithoutASourceToo() {
        guard case .ambiguousInAccount(let found) = resolve([pairOne, pairTwo], name: "Calendar A") else {
            return XCTFail("a pair in one account is ambiguous when no source is given")
        }
        XCTAssertEqual(found, [pairOne, pairTwo])
    }

    func testOneMatchingCalendarIsUsed() {
        guard case .found(let cal) = resolve([pairOne, work], name: "Calendar A", source: "iCloud") else {
            return XCTFail("one match is used")
        }
        XCTAssertEqual(cal, pairOne)
    }

    func testTheSourceNarrowsTwoAccountsToOne() {
        guard case .found(let cal) = resolve([pairOne, googlePair], name: "Calendar A", source: "Google") else {
            return XCTFail("the source picks the Google calendar")
        }
        XCTAssertEqual(cal, googlePair)
    }

    func testTwoAccountsWithoutASourceAreAmbiguousByAccount() {
        guard case .ambiguousAccounts(let found) = resolve([pairOne, googlePair], name: "Calendar A") else {
            return XCTFail("a name two accounts share needs the source")
        }
        XCTAssertEqual(found, [pairOne, googlePair])
    }

    func testNothingMatchingIsNotFound() {
        guard case .notFound = resolve([pairOne, work], name: "Nope") else { return XCTFail("no match is not found") }
        guard case .notFound = resolve([pairOne, work], name: "Calendar A", source: "Exchange") else {
            return XCTFail("a source nothing matches is not found")
        }
    }

    func testTheExistingCaseRuleStillApplies() {
        let lower = Cal(id: "L1", title: "calendar a")
        guard case .found(let exact) = resolve([pairOne, lower], name: "Calendar A") else { return XCTFail("exact wins") }
        XCTAssertEqual(exact, pairOne)
        guard case .found(let loose) = resolve([lower, work], name: "CALENDAR A") else { return XCTFail("case ignored when no exact") }
        XCTAssertEqual(loose, lower)
    }

    // MARK: spec-example: calendar-resolution / a refusal names ids and no titles

    func testIdsAreListedOnlyWhenEveryOneIsPlain() {
        XCTAssertEqual(CalendarCandidateIDs.listable(["A1B2-C3", "D4E5-F6"]), ["A1B2-C3", "D4E5-F6"])
        XCTAssertEqual(CalendarCandidateIDs.listable(["A1B2-C3", "has space"]), [])
        XCTAssertEqual(CalendarCandidateIDs.listable(["A1B2-C3", ""]), [])
        XCTAssertEqual(CalendarCandidateIDs.listable(["A1B2-C3", String(repeating: "a", count: 65)]), [])
        XCTAssertEqual(CalendarCandidateIDs.listable([String(repeating: "a", count: 64)]), [String(repeating: "a", count: 64)])
        XCTAssertEqual(CalendarCandidateIDs.listable(["ok", "line\nbreak"]), [])
    }

    // MARK: spec-example: calendar-resolution / calendar_id against name and source

    func testAnIdSelectsOneOfTwoSameTitleCalendars() {
        guard case .found(let cal) = resolve([pairOne, pairTwo], id: "D4E5-F6") else { return XCTFail("the id picks one") }
        XCTAssertEqual(cal, pairTwo)
    }

    func testAnIdAgreeingWithNameAndSourceIsUsed() {
        guard case .found(let cal) = resolve([pairOne, pairTwo], name: "Calendar A", source: "iCloud", id: "A1B2-C3") else {
            return XCTFail("an id that agrees is used")
        }
        XCTAssertEqual(cal, pairOne)
    }

    func testAnIdDisagreeingWithTheNameIsRefused() {
        guard case .idMismatch = resolve([pairOne, work], name: "Work", id: "A1B2-C3") else {
            return XCTFail("the name does not match the id's calendar")
        }
    }

    func testAnIdDisagreeingWithTheSourceIsRefused() {
        guard case .idMismatch = resolve([pairOne, googlePair], name: "Calendar A", source: "Google", id: "A1B2-C3") else {
            return XCTFail("the source does not match the id's calendar")
        }
        guard case .idMismatch = resolve([pairOne, googlePair], source: "Google", id: "A1B2-C3") else {
            return XCTFail("a source alone is checked against the id's calendar too")
        }
    }

    func testAnIdNoCalendarOfTheKindHasIsNotFound() {
        guard case .notFound = resolve([pairOne, pairTwo], id: "NOPE") else { return XCTFail("an unknown id is not found") }
        guard case .notFound = resolve([pairOne, pairTwo], name: "Calendar A", id: "NOPE") else {
            return XCTFail("an unknown id is not found even with a name")
        }
    }

    func testNameAndSourceCompareTheWayTheLookupDoes() {
        guard case .found(let cal) = resolve([pairOne], name: "calendar a", source: "ICLOUD", id: "A1B2-C3") else {
            return XCTFail("the same case rule applies to an id's name and source")
        }
        XCTAssertEqual(cal, pairOne)
    }
}
