import MCP
import XCTest
@testable import CheICalMCP

/// #506: when #503's check went up to a horizon on a series it could not list whole, `update_event`'s
/// response names the date it checked until and says that later deletions were not checked. Driven
/// through `FakeEventWriteSource` (an id starting with `horizon-`).
final class DeletedOccurrenceHorizonHandlerTests: XCTestCase {
    private func call(_ args: [String: Value]) async throws -> [String: Any] {
        let server = try await CheICalMCPServer(eventWriteSource: FakeEventWriteSource())
        let raw = try await server.executeToolCall(name: "update_event", arguments: args)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    func testTheResponseNamesTheDateCheckedUntilInTheEventsZone() async throws {
        let result = try await call(["event_id": .string("horizon-series"), "start_time": .string("2027-04-10T15:00:00+08:00"),
                                     "span": .string("all")])
        let expected = OccurrenceStart.string(FakeEventWriteSource.horizonUntil, zone: FakeEventWriteSource.horizonZone)
        XCTAssertEqual(result["deleted_occurrences_checked_until"] as? String, expected)
        XCTAssertTrue(expected.hasSuffix("-04:00") || expected.hasSuffix("-05:00"), expected)
        XCTAssertEqual(result["deleted_occurrences_note"] as? String, DeletedOccurrenceCheck.horizonNote(checkedUntil: expected))
        XCTAssertEqual(result["action"] as? String, "updated")
    }

    /// The tool description names the fields, and start_time no longer says an open-ended series is refused.
    func testTheDescriptionsNameTheHorizon() throws {
        let tool = try XCTUnwrap(CheICalMCPServer.defineTools().first { $0.name == "update_event" })
        let description = tool.description ?? ""
        // Docs pins occur exactly once, so a second copy left behind by an edit is caught.
        XCTAssertEqual(SourcePins.ranges(of: "the response adds deleted_occurrences_checked_until", in: description).count, 1, description)
        XCTAssertEqual(SourcePins.ranges(of: "was not checked and may have come back with the write", in: description).count, 1, description)
        let schema = "\(String(describing: tool.inputSchema))"
        XCTAssertEqual(SourcePins.ranges(of: "the listing does not reach two years from now without a gap from the first occurrence the write reaches", in: schema).count, 1, schema)
        XCTAssertFalse(schema.contains("(not when: the series is open-ended,"), schema)
        for reason in [SeriesRuleWrite.startPassesOccurrencesReason, SeriesRuleWrite.laterStartReason, SeriesRuleWrite.zoneChangeReason] {
            XCTAssertTrue(reason.contains("is checked only up to about two years from now, #506)"), reason)
        }
    }

    func testNoHorizonFieldsWhenTheCheckDidNotUseOne() async throws {
        let result = try await call(["event_id": .string("series"), "start_time": .string("2027-04-10T15:00:00+08:00"),
                                     "span": .string("all")])
        XCTAssertNil(result["deleted_occurrences_checked_until"])
        XCTAssertNil(result["deleted_occurrences_note"])
    }
}
