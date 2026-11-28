import EventKit
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

    // MARK: the resolver

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

    // MARK: the id format

    func testIdsAreListedOnlyWhenEveryOneIsPlain() {
        XCTAssertEqual(CalendarCandidateIDs.listable(["A1B2-C3", "D4E5-F6"]), ["A1B2-C3", "D4E5-F6"])
        XCTAssertEqual(CalendarCandidateIDs.listable(["A1B2-C3", "has space"]), [])
        XCTAssertEqual(CalendarCandidateIDs.listable(["A1B2-C3", ""]), [])
        XCTAssertEqual(CalendarCandidateIDs.listable(["A1B2-C3", String(repeating: "a", count: 65)]), [])
        XCTAssertEqual(CalendarCandidateIDs.listable([String(repeating: "a", count: 64)]), [String(repeating: "a", count: 64)])
        XCTAssertEqual(CalendarCandidateIDs.listable(["ok", "line\nbreak"]), [])
    }

    // MARK: calendar_id in the resolver

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

    // MARK: - The lookup and its refusals (`CalendarLookup.one`), on calendars of two kinds

    private func lookup(events: [Cal], reminders: [Cal] = [], kind: EKEntityType = .event, name: String? = nil,
                        source: String? = nil, id: String? = nil, offersID: Bool = true) throws -> Cal {
        try CalendarLookup.one(kind: kind, candidates: { $0 == .event ? events : reminders }, name: name, source: source,
                               id: id, offersID: offersID, identifier: \.id, title: \.title, sourceTitle: \.source)
    }

    /// The text a caller gets for what `lookup` throws, through the response sanitizer.
    private func refusal(_ body: () throws -> Cal, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            let cal = try body()
            XCTFail("expected a refusal, got \(cal)", file: file, line: line)
            return ""
        } catch {
            return EventKitErrorSanitizer.sanitizeForResponse(error).code
        }
    }

    /// spec-example: calendar-resolution / two calendars in one account are refused
    func testTheExampleOfTwoCalendarsInOneAccount() throws {
        let first = Cal(id: "A1B2-C3", title: "Calendar A")
        let second = Cal(id: "D4E5-F6", title: "Calendar A")
        let text = refusal { try lookup(events: [first, second], name: "Calendar A", source: "iCloud") }
        XCTAssertTrue(text.hasPrefix("2 calendars match"), text)
        XCTAssertTrue(text.contains("Their ids: A1B2-C3, D4E5-F6."), text)
        XCTAssertEqual(try lookup(events: [first], name: "Calendar A", source: "iCloud"), first)
        let reminderList = Cal(id: "R1", title: "Calendar A")
        XCTAssertEqual(try lookup(events: [first], reminders: [reminderList], name: "Calendar A"), first)
    }

    /// spec-example: calendar-resolution / a refusal names ids and no titles
    func testTheExampleOfWhatARefusalNames() {
        let rows: [(ids: [String], listed: Bool)] = [(["A1B2-C3", "D4E5-F6"], true), (["A1B2-C3", "has space"], false),
                                                     (["A1B2-C3", "\u{212A}1"], false)]
        for row in rows {
            let calendars = row.ids.map { Cal(id: $0, title: "Zebra Title", source: "Quartz Source") }
            let text = refusal { try lookup(events: calendars, name: "zebra title", source: "quartz source") }
            XCTAssertEqual(text.contains("Their ids"), row.listed, text)
            XCTAssertFalse(text.lowercased().contains("zebra"), text)
            XCTAssertFalse(text.lowercased().contains("quartz"), text)
        }
    }

    /// spec-example: calendar-resolution / two accounts without a source keep the earlier refusal
    func testTheExampleOfTwoAccountsWithoutASource() {
        let calendars = [Cal(id: "I1", title: "Calendar A", source: "iCloud"), Cal(id: "G1", title: "Calendar A", source: "Google")]
        let text = refusal { try lookup(events: calendars, name: "Calendar A") }
        XCTAssertEqual(text, "Multiple calendars found with name 'Calendar A'. Please specify calendar_source to disambiguate (use list_calendars to enumerate).")
    }

    /// spec-example: calendar-resolution / calendar_id against name and source
    func testTheExampleOfCalendarIDAgainstNameAndSource() throws {
        let first = Cal(id: "P1", title: "Calendar A")
        let events = [first, Cal(id: "P2", title: "Calendar A"), Cal(id: "W1", title: "Work")]
        let reminders = [Cal(id: "R1", title: "Calendar A")]
        XCTAssertEqual(try lookup(events: events, reminders: reminders, id: "P1"), first)
        XCTAssertEqual(try lookup(events: events, reminders: reminders, name: "Calendar A", source: "iCloud", id: "P1"), first)
        for (name, source) in [("Work", nil), ("Calendar A", "Google")] as [(String, String?)] {
            let text = refusal { try lookup(events: events, reminders: reminders, name: name, source: source, id: "P1") }
            XCTAssertTrue(text.hasPrefix("calendar_id selects a calendar that"), text)
        }
        XCTAssertEqual(refusal { try lookup(events: events, reminders: reminders, id: "R1") }, "Calendar not found: R1")
        XCTAssertEqual(refusal { try lookup(events: events, reminders: reminders, id: "NOPE") }, "Calendar not found: NOPE")
        XCTAssertEqual(refusal { try lookup(events: events, reminders: reminders, name: "Calendar A", id: "") },
                       "Calendar not found: (empty calendar_id)")
        // The other kind's lookup finds the reminder list by the same id.
        XCTAssertEqual(try lookup(events: events, reminders: reminders, kind: .reminder, id: "R1"), reminders[0])
    }

    func testARefusalWithoutAnIDNamesTheMissingCalendarAsBefore() {
        XCTAssertEqual(refusal { try lookup(events: [work], name: "Nope") }, "Calendar not found: Nope")
        XCTAssertEqual(refusal { try lookup(events: [work], name: "Nope", source: "iCloud") },
                       "Calendar 'Nope' not found in source 'iCloud'")
    }

    // MARK: - Which call site offers calendar_id

    private func count(_ needle: String, in file: String, file testFile: StaticString = #filePath, line: UInt = #line) throws -> Int {
        let code = SourceScan.collapsingWhitespace(SourceScan.strippingComments(try SourcePins.source(file)))
        return SourcePins.ranges(of: needle, in: code).count
    }

    /// spec-example: calendar-resolution / the remedy follows the tool
    /// The text follows the flag, run here; the flag each lookup passes is pinned in the source, since the
    /// manager cannot run without a store.
    func testTheExampleOfTheRemedyFollowingTheTool() throws {
        let pair = [Cal(id: "P1", title: "Calendar A"), Cal(id: "P2", title: "Calendar A")]
        XCTAssertTrue(refusal { try lookup(events: pair, name: "Calendar A", offersID: true) }.contains("Pass calendar_id"))
        let rename = refusal { try lookup(events: pair, name: "Calendar A", offersID: false) }
        XCTAssertTrue(rename.contains("rename one of the calendars"), rename)
        XCTAssertFalse(rename.contains("Pass calendar_id"), rename)

        let manager = "EventKit/EventKitManager.swift"
        // create_event and update_event's new calendar are the only literal `true` in the manager.
        XCTAssertEqual(try count("offersID: true", in: manager), 2)
        XCTAssertEqual(try count("findCalendar(name: calendarName, source: calendarSource, id: calendarID, offersID: true, entityType: .event)", in: manager), 2)
        // The three event reads take the flag from their caller, default false.
        XCTAssertEqual(try count("findCalendars(name: calendarName, source: calendarSource, id: calendarID, offersID: offersID, entityType: .event)", in: manager), 3)
        XCTAssertEqual(try count("calendarID: String? = nil, offersID: Bool = false", in: manager), 3,
                       "listEvents, searchEvents and checkConflicts")
        // Only the three range reads that take a calendar_id pass true.
        XCTAssertEqual(try count("offersID: true", in: "EventRangeReadSource.swift"), 3)
        // The batch delete's listing passes nothing, so it is told to rename.
        XCTAssertEqual(try count("offersID", in: "EventBatchDeletionSource.swift"), 0)
        XCTAssertEqual(try count("try await listEvents(startDate: startDate, endDate: endDate, calendarName: calendarName, calendarSource: calendarSource)", in: "EventBatchDeletionSource.swift"), 1)
    }

    func testTheManagerLooksUpOnlyCalendarsOfTheRequestedKind() throws {
        let manager = try SourcePins.source("EventKit/EventKitManager.swift")
        let body = try XCTUnwrap(SourcePins.body(of: "private func resolveCalendar(", in: manager))
        XCTAssertEqual(SourcePins.ranges(of: "CalendarLookup.one(", in: body).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "candidates: { eventStore.calendars(for: $0) }", in: body).count, 1)
        XCTAssertFalse(body.contains("calendar(withIdentifier:"), "an id lookup that skips the kind filter")
    }

    /// If one of the manager's `calendarID:` reads drifted from the protocol, the protocol's default
    /// would answer it and refuse every `calendar_id` in production.
    func testTheManagerImplementsTheThreeReadsThatTakeCalendarID() throws {
        let file = try SourcePins.source("EventRangeReadSource.swift")
        let manager = SourceScan.collapsingWhitespace(String(file[try XCTUnwrap(file.range(of: "extension EventKitManager:")).lowerBound...]))
        for signature in [
            "func listEventValues<Info: Sendable>(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?, calendarID: String?, pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info>",
            "func searchEventValues<Info: Sendable>(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?, calendarName: String?, calendarSource: String?, calendarID: String?, pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info>",
            "func checkConflictValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?, calendarID: String?, excludeEventId: String?) async throws -> [EventReadValue]"] {
            XCTAssertEqual(SourcePins.ranges(of: signature, in: manager).count, 1, signature)
        }
    }
}
