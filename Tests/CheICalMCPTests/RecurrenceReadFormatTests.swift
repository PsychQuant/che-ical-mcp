import EventKit
import XCTest
@testable import CheICalMCP

final class RecurrenceReadFormatTests: XCTestCase {
    func testEventAliasAndFieldsPreserveLegacyArray() async throws {
        let server = try await CheICalMCPServer()
        let event = FakeFormattableEvent()
        let result = server.formatEventDict(event)
        let legacy = try XCTUnwrap(result["recurrence_rules"] as? [[String: Any]])
        let named = try XCTUnwrap(result["event_recurrence_rules"] as? [[String: Any]])
        XCTAssertEqual(try formatJSON(legacy), try formatJSON(named))
        let selected = server.formatEventDict(event, fields: ["event_recurrence_rules"])
        XCTAssertNotNil(selected["event_recurrence_rules"])
        XCTAssertNil(selected["recurrence_rules"])
        XCTAssertNil(server.formatEventDict(event, detailLevel: "summary")["event_recurrence_rules"])
        XCTAssertNil(server.formatEventDict(FakeFormattableEvent(recurrenceRulesFragment: nil))["event_recurrence_rules"])
    }
    func testReminderAliasPreservesEveryRuleAndMissingStates() throws {
        let rule = ReminderRecurrenceRuleValue(from: EKRecurrenceRule(recurrenceWith: .weekly, interval: 2, end: nil))
        for (recurring, rules) in [(false, Optional<[ReminderRecurrenceRuleValue]>.none), (true, nil), (true, []), (true, [rule, rule])] {
            let result = reminderMetadata(hasRecurrence: recurring, rules: rules, due: nil)
            let named = try XCTUnwrap(result["reminder_recurrence_rules"])
            let legacy = try XCTUnwrap(result["recurrence_rules"])
            XCTAssertEqual(try formatJSON(["value": named]), try formatJSON(["value": legacy]))
        }
    }
    func testUnknownFrequencyNameDoesNotTrap() {
        XCTAssertEqual(eventRecurrenceFrequencyName(rawValue: 999), "unknown")
        XCTAssertEqual(eventRecurrenceFrequencyName(rawValue: -1), "unknown")
        XCTAssertEqual(eventRecurrenceFrequencyName(rawValue: EKRecurrenceFrequency.weekly.rawValue), "weekly")
    }
}
