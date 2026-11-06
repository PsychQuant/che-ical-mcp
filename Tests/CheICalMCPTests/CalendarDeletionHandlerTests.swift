import MCP
import XCTest
@testable import CheICalMCP

/// #328: `delete_calendar` through the `CalendarDeletionSource` seam: `require_empty` is a strict
/// boolean, defaults to false (the call is unchanged), and a checked delete reports what it searched.
private actor CalendarDeletionFake: CalendarDeletionSource {
    struct Call: Equatable { let identifier: String; let requireEmpty: Bool }
    private(set) var calls: [Call] = []
    let checked: CalendarEmptiness.Checked?

    init(checked: CalendarEmptiness.Checked? = nil) { self.checked = checked }

    func deleteCalendar(identifier: String, requireEmpty: Bool) async throws -> CalendarEmptiness.Checked? {
        calls.append(Call(identifier: identifier, requireEmpty: requireEmpty))
        return requireEmpty ? checked : nil
    }
}

final class CalendarDeletionHandlerTests: XCTestCase {
    private func call(_ fake: CalendarDeletionFake, _ args: [String: Value]) async throws -> String {
        let server = try await CheICalMCPServer(calendarDeletionSource: fake)
        return try await server.executeToolCall(name: "delete_calendar", arguments: args)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], text)
    }

    func testWithoutRequireEmptyTheCallIsUnchanged() async throws {
        let fake = CalendarDeletionFake()
        let text = try await call(fake, ["id": .string("cal-1")])
        let calls = await fake.calls
        XCTAssertEqual(calls, [.init(identifier: "cal-1", requireEmpty: false)])
        let body = try json(text)
        XCTAssertEqual(Set(body.keys), ["action", "id"], "the answer is the one before #328: \(text)")
        XCTAssertEqual(body["action"] as? String, "deleted")
        XCTAssertEqual(body["id"] as? String, "cal-1")
    }

    /// PR #413 verify r1: the description says, before the call, what is checked and what the
    /// answer carries.
    func testTheDescriptionStatesTheWindowAndTheAnswerFields() throws {
        let tool = try XCTUnwrap(CheICalMCPServer.defineTools().first { $0.name == "delete_calendar" })
        let text = tool.description ?? ""
        for field in ["checked_empty", "searched_from", "searched_to", "reminders_found", "200 years", "0026", "not undoable",
                      "not yet synced", "this server process", "both"] {
            XCTAssertTrue(text.contains(field), "\(field): \(text)")
        }
    }

    func testACheckedDeleteReportsTheSearchedWindow() async throws {
        let window = EventRangeQuery.Span(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 86_400))
        let fake = CalendarDeletionFake(checked: .init(searched: window, reminders: nil))
        let text = try await call(fake, ["id": .string("cal-1"), "require_empty": .bool(true)])
        let calls = await fake.calls
        XCTAssertEqual(calls, [.init(identifier: "cal-1", requireEmpty: true)])
        let body = try json(text)
        XCTAssertEqual(body["searched_from"] as? String, EventRangeQuery.localText(window.start), text)
        XCTAssertEqual(body["searched_to"] as? String, EventRangeQuery.localText(window.end), text)
        XCTAssertEqual(body["checked_empty"] as? Bool, true, text)
    }

    func testACheckedListDeleteReportsZeroReminders() async throws {
        let fake = CalendarDeletionFake(checked: .init(searched: nil, reminders: 0))
        let text = try await call(fake, ["id": .string("list-1"), "require_empty": .bool(true)])
        let body = try json(text)
        XCTAssertEqual(body["reminders_found"] as? Int, 0, text)
        XCTAssertNil(body["searched_from"], text)
    }

    /// PR #413 round 2: the switch guards an irreversible delete, so null and a misspelled key do
    /// not fall back to the unchecked delete.
    func testNullAndUnknownKeysAreRefusedWithNothingDeleted() async throws {
        let cases: [([String: Value], String)] = [
            (["id": .string("cal-1"), "require_empty": .null], "require_empty must be true or false"),
            (["id": .string("cal-1"), "requireEmpty": .bool(true)], "It accepts: id, require_empty."),
            (["id": .string("cal-1"), "require-empty": .bool(true)], "It accepts: id, require_empty."),
        ]
        for (args, expected) in cases {
            let fake = CalendarDeletionFake()
            do {
                _ = try await call(fake, args)
                XCTFail("\(args) must be refused")
            } catch let error as ToolError {
                XCTAssertTrue("\(error)".contains(expected), "\(args): \(error)")
                XCTAssertFalse("\(error)".contains("requireEmpty") || "\(error)".contains("require-empty"),
                               "the caller's key is not echoed into the trusted text: \(error)")
            }
            let calls = await fake.calls
            XCTAssertEqual(calls, [], "\(args): nothing deleted")
        }
    }

    func testRequireEmptyMustBeABoolean() async throws {
        for bad: Value in [.string("true"), .int(1)] {
            let fake = CalendarDeletionFake()
            do {
                _ = try await call(fake, ["id": .string("cal-1"), "require_empty": bad])
                XCTFail("\(bad) must be refused")
            } catch let error as ToolError {
                XCTAssertTrue("\(error)".contains("require_empty must be a boolean (true or false)"), "\(bad): \(error)")
            }
            let calls = await fake.calls
            XCTAssertEqual(calls, [], "\(bad): nothing deleted")
        }
    }
}
