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
        XCTAssertFalse(text.contains("searched_from"), text)
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

    func testRequireEmptyMustBeABoolean() async throws {
        let fake = CalendarDeletionFake()
        let result = try? await call(fake, ["id": .string("cal-1"), "require_empty": .string("true")])
        let calls = await fake.calls
        XCTAssertEqual(calls, [], "nothing deleted on a bad argument: \(String(describing: result))")
    }
}
