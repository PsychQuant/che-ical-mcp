import EventKit
import Foundation
import MCP
import XCTest
@testable import CheICalMCP

private actor CompletionFake: ReminderCompletionSource {
    var calls = 0
    let fail: Bool
    let confirmed: Bool
    init(fail: Bool = false, confirmed: Bool = false) { self.fail = fail; self.confirmed = confirmed }
    func completeReminder(identifier: String, completed: Bool) async throws -> ReminderCompletionResult {
        calls += 1
        if fail { throw ToolError.invalidParameter("simulated save failure") }
        if confirmed {
            let rule = ReminderRecurrenceRuleValue(from: EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
            func snap(day: Int) -> ReminderCompletionSnapshot {
                ReminderCompletionSnapshot(id: identifier, title: "Repeat", calendarID: "list", sourceID: "source",
                                           isCompleted: false, hasRecurrence: true,
                                           due: ReminderDueValue(components: DateComponents(year: 2026, month: 9, day: day)), rules: [rule], completionDate: nil)
            }
            let before = snap(day: 5), after = snap(day: 6)
            return ReminderCompletionResult(before: before, afterSave: after, requestedCompleted: completed,
                                            nextOccurrence: .evaluate(before: before, observed: after, requestedCompleted: completed))
        }
        let before = ReminderCompletionSnapshot(id: identifier, title: "Repeat", calendarID: "list", sourceID: "source", isCompleted: false, hasRecurrence: true, due: nil, rules: nil, completionDate: nil)
        return ReminderCompletionResult(before: before, afterSave: before, requestedCompleted: completed, nextOccurrence: completed ? .unknown(reason: "not_observed") : .notApplicable)
    }
}

final class ReminderCompletionHandlerTests: XCTestCase {
    func testSuccessfulCompletionIsIndependentOfIncompleteObject() async throws {
        let fake = CompletionFake()
        let server = try await CheICalMCPServer(reminderCompletionSource: fake)
        let raw = try await server.executeToolCall(name: "complete_reminder", arguments: ["reminder_id": .string("r")])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(json["action"] as? String, "completed")
        XCTAssertEqual(json["is_completed"] as? Bool, false)
        XCTAssertEqual(json["has_recurrence"] as? Bool, true)
        let operation = try XCTUnwrap(json["operation"] as? [String: Any])
        XCTAssertEqual(operation["status"] as? String, "succeeded")
        XCTAssertEqual(operation["type"] as? String, "complete")
        let next = try XCTUnwrap(json["next_occurrence"] as? [String: Any])
        XCTAssertEqual(next["status"] as? String, "unknown")
        let calls = await fake.calls
        XCTAssertEqual(calls, 1)
    }

    func testReopenReportsRequestedActionWithoutChangingLegacyAction() async throws {
        let server = try await CheICalMCPServer(reminderCompletionSource: CompletionFake())
        let raw = try await server.executeToolCall(name: "complete_reminder", arguments: ["reminder_id": .string("r"), "completed": .bool(false)])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let operation = try XCTUnwrap(json["operation"] as? [String: Any])
        XCTAssertEqual(operation["type"] as? String, "reopen")
        XCTAssertEqual(operation["requested_completed"] as? Bool, false)
        XCTAssertEqual(json["action"] as? String, "completed")
    }


    func testConfirmedSuccessorReachesTheJSONEnvelope() async throws {
        let server = try await CheICalMCPServer(reminderCompletionSource: CompletionFake(confirmed: true))
        let raw = try await server.executeToolCall(name: "complete_reminder", arguments: ["reminder_id": .string("r")])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let next = try XCTUnwrap(json["next_occurrence"] as? [String: Any])
        XCTAssertEqual(next["status"] as? String, "confirmed")
        let reminder = try XCTUnwrap(next["reminder"] as? [String: Any])
        XCTAssertEqual((reminder["due"] as? [String: Any])?["date"] as? String, "2026-09-06")
        XCTAssertTrue((json["message"] as? String ?? "").contains("2026-09-06"))
        let observed = try XCTUnwrap(json["observed"] as? [String: Any])
        XCTAssertEqual((observed["due"] as? [String: Any])?["date"] as? String, "2026-09-06")
    }

    func testNonBooleanCompletedIsRejectedBeforeWriting() async throws {
        let fake = CompletionFake()
        let server = try await CheICalMCPServer(reminderCompletionSource: fake)
        for bad in [Value.string("false"), .string("true"), .int(0), .int(1), .double(1)] {
            do {
                _ = try await server.executeToolCall(name: "complete_reminder", arguments: ["reminder_id": .string("r"), "completed": bad])
                XCTFail("must reject non-boolean completed: \(bad)")
            } catch let error as ToolError {
                XCTAssertTrue("\(error)".contains("completed must be a boolean"), "\(error)")
            }
        }
        let calls = await fake.calls
        XCTAssertEqual(calls, 0, "a rejected argument must never reach the store")
    }

    func testNullCompletedIsTreatedAsOmitted() async throws {
        let fake = CompletionFake()
        let server = try await CheICalMCPServer(reminderCompletionSource: fake)
        let raw = try await server.executeToolCall(name: "complete_reminder", arguments: ["reminder_id": .string("r"), "completed": .null])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual((json["operation"] as? [String: Any])?["type"] as? String, "complete")
        let calls = await fake.calls
        XCTAssertEqual(calls, 1)
    }
}
