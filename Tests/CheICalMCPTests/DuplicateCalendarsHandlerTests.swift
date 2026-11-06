import MCP
import XCTest
@testable import CheICalMCP

private actor DuplicateSearchFake: DuplicateSearchSource {
    private(set) var names: [[String]?] = []
    private let checked: [String]
    private let pairs: [DuplicatePair]
    private let error: Error?

    init(checked: [String] = ["A", "B"], pairs: [DuplicatePair] = [], error: Error? = nil) {
        self.checked = checked
        self.pairs = pairs
        self.error = error
    }

    func findDuplicateEvents(calendarNames: [String]?, startDate: Date, endDate: Date, toleranceMinutes: Int) async throws -> DuplicateSearchValue {
        names.append(calendarNames)
        if let error { throw error }
        return DuplicateSearchValue(calendarsChecked: checked, pairs: pairs)
    }
}

/// #437: what `find_duplicate_events` asks for and what it says it read.
final class DuplicateCalendarsHandlerTests: XCTestCase {
    private let range: [String: Value] = ["start_date": .string("2026-01-01"), "end_date": .string("2026-12-31")]

    private func call(_ fake: DuplicateSearchFake, _ extra: [String: Value] = [:]) async throws -> [String: Any] {
        let server = try await CheICalMCPServer(duplicateSearchSource: fake)
        let raw = try await server.executeToolCall(name: "find_duplicate_events", arguments: range.merging(extra) { $1 })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    /// The response names what was read, not what was asked for.
    func testCalendarsCheckedComesFromTheRead() async throws {
        let fake = DuplicateSearchFake(checked: ["Work", "Home"])
        let response = try await call(fake, ["calendar_names": .array([.string("work"), .string("home")])])
        XCTAssertEqual(response["calendars_checked"] as? [String], ["Work", "Home"])
        XCTAssertEqual(response["duplicate_count"] as? Int, 0)
        // Passed on as given: the match, and its case rule, are the manager's.
        let names = await fake.names
        XCTAssertEqual(names, [["work", "home"]])
    }

    /// PR #440 verify round 1: two accounts' calendars of one title are what is compared before
    /// merging, so each side of a pair says which account it is in, in the two fields the other
    /// tools take.
    func testEachSideOfAPairSaysItsAccount() async throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let pair = DuplicatePair(event1Id: "a", event1Title: "Lunch", event1Calendar: "Work", event1CalendarSource: "iCloud",
                                 event1StartDate: start, event2Id: "b", event2Title: "Lunch", event2Calendar: "Work",
                                 event2CalendarSource: "Google", event2StartDate: start, timeDifferenceSeconds: 0)
        let response = try await call(DuplicateSearchFake(checked: ["Work (iCloud)", "Work (Google)"], pairs: [pair]),
                                      ["calendar_names": .array([.string("Work")])])
        XCTAssertEqual(response["duplicate_count"] as? Int, 1)
        let row = try XCTUnwrap((response["duplicates"] as? [[String: Any]])?.first)
        let first = try XCTUnwrap(row["event1"] as? [String: Any])
        let second = try XCTUnwrap(row["event2"] as? [String: Any])
        XCTAssertEqual(first["calendar"] as? String, "Work")
        XCTAssertEqual(first["calendar_source"] as? String, "iCloud")
        XCTAssertEqual(second["calendar"] as? String, "Work")
        XCTAssertEqual(second["calendar_source"] as? String, "Google")
    }

    func testNoNamesReportsTheCalendarsRead() async throws {
        let fake = DuplicateSearchFake(checked: ["A", "B", "C"])
        let response = try await call(fake)
        XCTAssertEqual(response["calendars_checked"] as? [String], ["A", "B", "C"])
        let names = await fake.names
        XCTAssertEqual(names, [nil])
    }

    /// As documented: empty or absent reads all. JSON null is absent.
    func testAnEmptyOrNullListReadsAll() async throws {
        for value: Value in [.array([]), .null] {
            let fake = DuplicateSearchFake()
            _ = try await call(fake, ["calendar_names": value])
            let names = await fake.names
            XCTAssertEqual(names, [nil], "\(value)")
        }
    }

    /// These used to read all calendars, or fewer than were named, without a word.
    func testNamesThatAreNotAnArrayOfStringsAreRefusedBeforeAnyRead() async throws {
        for value: Value in [.string("Work"), .int(3), .object(["a": .string("b")]), .array([.string("Work"), .int(3)]),
                             .array([.string("Work"), .null])] {
            let fake = DuplicateSearchFake()
            do {
                _ = try await call(fake, ["calendar_names": value])
                XCTFail("\(value) was read")
            } catch ToolError.invalidParameter(let message) {
                XCTAssertTrue(message.contains("calendar_names must be an array of strings"), message)
            }
            let names = await fake.names
            XCTAssertTrue(names.isEmpty, "\(value)")
        }
    }

    /// PR #440 verify round 1: the names the other tools use for this. Ignored, each would read
    /// every calendar, and `calendar_source` would not narrow a name two accounts share.
    func testTheOtherToolsCalendarParametersAreRefusedBeforeAnyRead() async throws {
        for (key, value) in [("calendar_name", Value.string("Work")), ("calendar_source", .string("iCloud")),
                             ("calendars", .array([.string("Work"), .string("Home")]))] {
            let fake = DuplicateSearchFake()
            do {
                _ = try await call(fake, ["calendar_names": .array([.string("Work"), .string("Home")]), key: value])
                XCTFail("\(key) was ignored")
            } catch ToolError.invalidParameter(let message) {
                XCTAssertTrue(message.contains("does not take \(key)"), message)
                XCTAssertTrue(message.contains("calendar_names"), message)
            }
            let names = await fake.names
            XCTAssertTrue(names.isEmpty, key)
        }
    }

    /// JSON null is absent, as it is for `calendar_names`.
    func testANullOtherParameterIsAbsent() async throws {
        let fake = DuplicateSearchFake()
        _ = try await call(fake, ["calendar_source": .null])
        let names = await fake.names
        XCTAssertEqual(names, [nil])
    }

    /// The refusals pass through with their own text.
    func testARefusalReachesTheCaller() async throws {
        for (error, phrase) in [(EventKitError.tooFewCalendarsToCompare(found: 1, named: true), "at least two"),
                                (EventKitError.calendarNotFound(identifier: "missing"), "missing")] as [(Error, String)] {
            let server = try await CheICalMCPServer(duplicateSearchSource: DuplicateSearchFake(error: error))
            let result = await server.handleToolCallForTesting(name: "find_duplicate_events", arguments: range)
            XCTAssertEqual(result.isError, true)
            guard case .text(let text, _, _)? = result.content.first else { return XCTFail() }
            XCTAssertTrue(text.contains(phrase), text)
        }
    }

    /// The read bound gets this tool's wording through the handler, as well as by the source pin.
    func testTheReadBoundIsWordedForThisTool() async throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let bound = EventRangeQuery.RangeError.tooManyEvents(limit: EventRangeQuery.maxEventsRead, from: base,
                                                             to: base.addingTimeInterval(86_400 * 36_500),
                                                             readThrough: base.addingTimeInterval(86_400 * 1460))
        let server = try await CheICalMCPServer(duplicateSearchSource: DuplicateSearchFake(error: bound))
        do {
            _ = try await server.executeToolCall(name: "find_duplicate_events", arguments: range)
            XCTFail("expected the read bound")
        } catch let error as EventRangeQuery.RangeError {
            XCTAssertTrue(error.localizedDescription.contains("at least two"), error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.contains("read one"), error.localizedDescription)
        }
    }
}
