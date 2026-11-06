import CheMCPKit
import XCTest
@testable import CheICalMCP

/// #437: the one rule for matching a calendar name, and what `find_duplicate_events` makes of it.
final class CalendarNameMatchTests: XCTestCase {
    private struct Cal: Equatable {
        let id: String
        let title: String
        var source = "iCloud"
    }

    private func match(_ all: [Cal], _ name: String, source: String? = nil) -> [Cal] {
        CalendarNameMatch.matching(all, name: name, source: source, title: \.title, sourceTitle: \.source)
    }

    private func resolve(_ names: [String]?, _ all: [Cal]) throws -> [Cal] {
        try DuplicateCalendars.resolve(names: names, among: all, identifier: \.id, title: \.title, sourceTitle: \.source)
    }

    private let work = Cal(id: "1", title: "Work")
    private let home = Cal(id: "2", title: "Home")

    // MARK: the match

    func testAnExactMatchWinsOverACaseVariant() {
        let lower = Cal(id: "3", title: "work")
        XCTAssertEqual(match([work, lower], "Work"), [work])
        XCTAssertEqual(match([work, lower], "work"), [lower])
    }

    func testCaseIsIgnoredOnlyWhenNothingMatchesExactly() {
        let lower = Cal(id: "3", title: "work")
        XCTAssertEqual(match([work, lower, home], "WORK"), [work, lower])
        XCTAssertEqual(match([work], "nope"), [])
    }

    func testTheSourceNarrowsTheMatch() {
        let google = Cal(id: "3", title: "Work", source: "Google")
        XCTAssertEqual(match([work, google], "Work", source: "Google"), [google])
        XCTAssertEqual(match([work, google], "work", source: "GOOGLE"), [google])
        XCTAssertEqual(match([work, google], "Work", source: "Exchange"), [])
    }

    /// `findCalendar` and `findCalendars` keep their behaviour by using this function, not a copy,
    /// and keep their own refusals.
    func testTheManagersLookupsUseTheSharedMatch() throws {
        let manager = try SourcePins.source("EventKit/EventKitManager.swift")
        for declaration in ["func findCalendar(", "func findCalendars("] {
            let body = try XCTUnwrap(SourcePins.body(of: declaration, in: manager), declaration)
            XCTAssertEqual(SourcePins.ranges(of: "CalendarNameMatch.matching(", in: body).count, 1, declaration)
            // PR #440 verify round 1: `calendar_source` narrows the lookup only if it reaches the match.
            XCTAssertEqual(SourcePins.ranges(of: "CalendarNameMatch.matching(allCalendars, name: name, source: source,", in: body).count, 1, declaration)
            XCTAssertEqual(SourcePins.ranges(of: "sourceTitle: { $0.source.title }", in: body).count, 1, declaration)
            for refusal in ["calendarNotFoundWithSource(", "calendarNotFound(", "multipleCalendarsFound("] {
                XCTAssertEqual(SourcePins.ranges(of: "EventKitError.\(refusal)", in: body).count, 1, "\(declaration) \(refusal)")
            }
        }
    }

    /// PR #440 verify round 1: an in-memory store cannot run `findDuplicateEvents`, and restoring
    /// the old filter there would leave every other test green. It reads what the resolver resolved,
    /// reports what it read, and says which account each side of a pair is in.
    func testTheManagerReadsWhatTheResolverResolved() throws {
        let manager = try SourcePins.source("EventKit/EventKitManager.swift")
        let body = try XCTUnwrap(SourcePins.body(of: "func findDuplicateEvents(", in: manager))
        XCTAssertEqual(SourcePins.ranges(of: "let calendars = try DuplicateCalendars.resolve(", in: body).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "DuplicateCalendars.checkedLabels(calendars,", in: body).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "try self.events(from: startDate, to: endDate, calendars: calendars)", in: body).count, 1)
        let resolve = try XCTUnwrap(SourcePins.ranges(of: "DuplicateCalendars.resolve(", in: body).first)
        let read = try XCTUnwrap(SourcePins.ranges(of: "self.events(from:", in: body).first)
        XCTAssertLessThan(resolve.lowerBound, read.lowerBound)
        XCTAssertTrue(SourcePins.ranges(of: "names.contains", in: body).isEmpty)
        XCTAssertEqual(SourcePins.ranges(of: "event1CalendarSource: e1.calendar.source.title", in: body).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "event2CalendarSource: e2.calendar.source.title", in: body).count, 1)
    }

    // MARK: what find_duplicate_events reads

    func testNoNamesIsEveryCalendar() throws {
        XCTAssertEqual(try resolve(nil, [work, home]), [work, home])
    }

    func testNamesAreMatchedIgnoringCase() throws {
        XCTAssertEqual(try resolve(["work", "HOME"], [work, home]), [work, home])
    }

    /// Two accounts' calendars of one name are what is compared before merging: both are read and
    /// they count as two, though `findCalendars` would refuse the name.
    func testANameHeldByTwoAccountsReadsBoth() throws {
        let google = Cal(id: "3", title: "Work", source: "Google")
        XCTAssertEqual(try resolve(["Work"], [work, google]), [work, google])
    }

    func testANameThatMatchesNothingIsRefusedByName() {
        for names in [["Work", "missing"], ["missing", "Work"], ["missing", "other"]] {
            XCTAssertThrowsError(try resolve(names, [work, home]), "\(names)") { error in
                guard case EventKitError.calendarNotFound(let name, _) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(name, "missing")
            }
        }
    }

    func testFewerThanTwoCalendarsIsRefused() {
        let cases: [([String]?, [Cal], Int, Bool)] = [
            (["Work"], [work, home], 1, true),
            (["Work", "work", "WORK"], [work, home], 1, true),   // one calendar, named three ways
            (nil, [work], 1, false),
            (nil, [], 0, false)
        ]
        for (names, all, found, named) in cases {
            XCTAssertThrowsError(try resolve(names, all), "\(String(describing: names))") { error in
                guard case EventKitError.tooFewCalendarsToCompare(let count, let wasNamed) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(count, found)
                XCTAssertEqual(wasNamed, named)
            }
        }
    }

    func testTheRefusalSaysWhyAndIsTrusted() {
        let error = EventKitError.tooFewCalendarsToCompare(found: 1, named: true)
        XCTAssertTrue((error as Error) is TrustedErrorMessage)
        let text = error.localizedDescription
        for phrase in ["at least two", "1 found", "different calendars", "Nothing was returned", "calendar_names"] {
            XCTAssertTrue(text.contains(phrase), "\(phrase): \(text)")
        }
    }

    /// PR #440 verify round 1: with no names there is nothing to name, so the refusal must not
    /// tell the caller to name more.
    func testTheRefusalWithNoNamesDoesNotAdviseNamingMore() {
        let text = EventKitError.tooFewCalendarsToCompare(found: 1, named: false).localizedDescription
        for phrase in ["at least two", "this host has 1", "Nothing was returned"] {
            XCTAssertTrue(text.contains(phrase), "\(phrase): \(text)")
        }
        XCTAssertFalse(text.contains("calendar_names"), text)
    }

    // MARK: calendars_checked

    func testTheLabelsAreTitlesWithTheAccountOnlyWhereATitleRepeats() {
        let google = Cal(id: "3", title: "Work", source: "Google")
        let labels = { (all: [Cal]) in DuplicateCalendars.checkedLabels(all, title: \.title, sourceTitle: \.source) }
        XCTAssertEqual(labels([work, home]), ["Work", "Home"])
        XCTAssertEqual(labels([work, google, home]), ["Work (iCloud)", "Work (Google)", "Home"])
    }
}
