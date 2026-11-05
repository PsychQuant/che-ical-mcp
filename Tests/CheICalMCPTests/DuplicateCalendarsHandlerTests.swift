import MCP
import XCTest
@testable import CheICalMCP

private actor DuplicateSearchFake: DuplicateSearchSource {
    private(set) var names: [[String]?] = []
    private let checked: [String]
    private let error: Error?

    init(checked: [String] = ["A", "B"], error: Error? = nil) {
        self.checked = checked
        self.error = error
    }

    func findDuplicateEvents(calendarNames: [String]?, startDate: Date, endDate: Date, toleranceMinutes: Int) async throws -> DuplicateSearchValue {
        names.append(calendarNames)
        if let error { throw error }
        return DuplicateSearchValue(calendarsChecked: checked, pairs: [])
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
        let response = try await call(DuplicateSearchFake(checked: ["Work", "Home"]), ["calendar_names": .array([.string("work"), .string("home")])])
        XCTAssertEqual(response["calendars_checked"] as? [String], ["Work", "Home"])
        XCTAssertEqual(response["duplicate_count"] as? Int, 0)
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

    /// The refusals pass through with their own text.
    func testARefusalReachesTheCaller() async throws {
        for (error, phrase) in [(EventKitError.tooFewCalendarsToCompare(found: 1), "at least two"),
                                (EventKitError.calendarNotFound(identifier: "missing"), "missing")] as [(Error, String)] {
            let server = try await CheICalMCPServer(duplicateSearchSource: DuplicateSearchFake(error: error))
            let result = await server.handleToolCallForTesting(name: "find_duplicate_events", arguments: range)
            XCTAssertEqual(result.isError, true)
            guard case .text(let text, _, _)? = result.content.first else { return XCTFail() }
            XCTAssertTrue(text.contains(phrase), text)
        }
    }

    /// Through the handler now, not a source pin: the read bound gets this tool's wording.
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
