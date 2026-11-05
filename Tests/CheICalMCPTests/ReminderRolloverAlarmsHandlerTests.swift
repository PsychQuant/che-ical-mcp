import EventKit
import Foundation
import MCP
import XCTest
@testable import CheICalMCP

/// #423 through the `complete_reminder` handler, with a completion fake.
private actor RolloverFake: ReminderCompletionSource {
    let alarms: ReminderRolloverAlarms?
    init(_ alarms: ReminderRolloverAlarms?) { self.alarms = alarms }
    func completeReminder(identifier: String, completed: Bool) async throws -> ReminderCompletionResult {
        let rule = ReminderRecurrenceRuleValue(from: EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil))
        func snap(day: Int) -> ReminderCompletionSnapshot {
            ReminderCompletionSnapshot(id: identifier, title: "Repeat", calendarID: "list", sourceID: "source", isCompleted: false,
                                       hasRecurrence: true, due: ReminderDueValue(components: DateComponents(year: 2026, month: 12, day: day)),
                                       rules: [rule], completionDate: nil)
        }
        return ReminderCompletionResult(before: snap(day: 10), afterSave: snap(day: 17), requestedCompleted: completed,
                                        nextOccurrence: .evaluate(before: snap(day: 10), observed: snap(day: 17), requestedCompleted: completed),
                                        rolloverAlarms: alarms)
    }
}

final class ReminderRolloverAlarmsHandlerTests: XCTestCase {
    private func call(_ alarms: ReminderRolloverAlarms?) async throws -> [String: Any] {
        let server = try await CheICalMCPServer(reminderCompletionSource: RolloverFake(alarms))
        let raw = try await server.executeToolCall(name: "complete_reminder", arguments: ["reminder_id": .string("r")])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    }

    func testAnAddedAlarmIsNamed() async throws {
        let json = try await call(ReminderRolloverAlarms(readBack: true, minutesBefore: [15, 0], added: [0]))
        XCTAssertEqual((json["next_occurrence"] as? [String: Any])?["alarms_minutes_offsets"] as? [Double], [15, 0])
        XCTAssertEqual(json["alarms_note"] as? String, ReminderRolloverAlarms.note(added: [0]))
    }

    func testNoAddedAlarmNoNote() async throws {
        let json = try await call(ReminderRolloverAlarms(readBack: true, minutesBefore: [15], added: []))
        XCTAssertEqual((json["next_occurrence"] as? [String: Any])?["alarms_minutes_offsets"] as? [Double], [15])
        XCTAssertNil(json["alarms_note"])
    }

    func testAnUnreadableNextOccurrenceClaimsNothing() async throws {
        let json = try await call(ReminderRolloverAlarms(readBack: false, minutesBefore: [], added: []))
        XCTAssertEqual((json["next_occurrence"] as? [String: Any])?["alarms_read_back"] as? Bool, false)
        XCTAssertNil((json["next_occurrence"] as? [String: Any])?["alarms_minutes_offsets"])
        XCTAssertEqual(json["alarms_read_back_note"] as? String, ReminderRolloverAlarms.unreadNote)
    }

    func testWithoutAnObservationTheResponseIsUnchanged() async throws {
        let json = try await call(nil)
        XCTAssertNil((json["next_occurrence"] as? [String: Any])?["alarms_minutes_offsets"])
        XCTAssertNil(json["alarms_note"])
    }

    func testTheToolDescriptionSaysWhatWasMeasured() throws {
        let description = CheICalMCPServer.defineTools().first { $0.name == "complete_reminder" }?.description ?? ""
        XCTAssertTrue(description.contains("next_occurrence.alarms_minutes_offsets"), description)
        XCTAssertTrue(description.contains("alarms_note"), description)
        XCTAssertTrue(description.contains("This call sets only the completion fields"), description)
        XCTAssertFalse(description.contains("writes no alarm"), description)
        XCTAssertTrue(description.contains("another app or a sync"), description)
        XCTAssertTrue(description.contains("location trigger"), description)
        XCTAssertTrue(description.contains("not checked"), description)
    }
}
