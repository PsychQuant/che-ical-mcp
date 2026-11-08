import EventKit
import MCP
import XCTest
@testable import CheICalMCP

/// #473: the value checks behind `ArgumentRangeHandlerTests`, as pure functions.
final class ArgumentRangeTests: XCTestCase {
    private func refusal(_ body: () throws -> Any?) -> String {
        do {
            _ = try body()
            XCTFail("taken")
            return ""
        } catch ToolError.invalidParameter(let message) {
            return message
        } catch {
            XCTFail("\(error)")
            return ""
        }
    }

    func testReminderPriorityReadsZeroToNineAndNullAsOmitted() throws {
        XCTAssertNil(try InputValidation.reminderPriority([:]))
        XCTAssertNil(try InputValidation.reminderPriority(["priority": .null]))
        XCTAssertEqual(try InputValidation.reminderPriority(["priority": .int(0)]), 0)
        XCTAssertEqual(try InputValidation.reminderPriority(["priority": .int(9)]), 9)
        XCTAssertEqual(try InputValidation.reminderPriority(["priority": .double(5)]), 5)
    }

    func testReminderPriorityRefusesOutOfRangeAndNonIntegers() {
        for value: Value in [.int(10), .int(-1), .int(100), .double(5.5), .string("5"), .bool(true)] {
            let message = refusal { try InputValidation.reminderPriority(["priority": value]) }
            XCTAssertTrue(message.contains("priority must be an integer from 0 to 9"), "\(value): \(message)")
            XCTAssertTrue(message.contains("9 = low"), "the values are named: \(message)")
        }
    }

    func testALocationTriggerHasTheDocumentedDefaultRadius() throws {
        let trigger = try LocationArguments.locationTrigger(["title": .string("Lab"), "latitude": .int(25), "longitude": .double(121.5),
                                                             "proximity": .string("leave")])
        XCTAssertEqual(trigger.radius, 100)
        XCTAssertEqual(trigger.proximity, .leave)
        XCTAssertEqual(trigger.longitude, 121.5)
    }

    func testAStructuredLocationWithNoCoordinatesHasNone() throws {
        let place = try LocationArguments.structuredLocation(["title": .string("Lab")])
        XCTAssertNil(place.latitude)
        XCTAssertNil(place.longitude)
        XCTAssertNil(place.radius)
        let nulls = try LocationArguments.structuredLocation(["title": .string("Lab"), "latitude": .null, "longitude": .null, "radius": .null])
        XCTAssertNil(nulls.latitude)
        XCTAssertNil(nulls.radius)
    }

    func testEachLocationRefusalNamesItsArgument() {
        let trigger: [String: Value] = ["title": .string("Lab"), "latitude": .int(25), "longitude": .int(121), "proximity": .string("enter")]
        let place: [String: Value] = ["title": .string("Lab"), "latitude": .int(25), "longitude": .int(121)]
        func with(_ base: [String: Value], _ key: String, _ value: Value?) -> [String: Value] {
            var copy = base
            copy[key] = value
            return copy
        }
        let cases: [([String: Value], Bool, String)] = [
            (with(trigger, "radius", .int(0)), true, "location_trigger.radius must be greater than 0"),
            (with(trigger, "latitude", .double(-90.01)), true, "location_trigger.latitude must be a number from -90 to 90"),
            (with(trigger, "longitude", .int(181)), true, "location_trigger.longitude must be a number from -180 to 180"),
            (with(trigger, "proximity", .string("ENTER")), true, #"location_trigger.proximity must be "enter" or "leave""#),
            (with(trigger, "proximity", nil), true, #"location_trigger.proximity is required: "enter" or "leave""#),
            (with(place, "radius", .double(-1)), false, "structured_location.radius must be greater than 0"),
            (with(place, "latitude", .int(91)), false, "structured_location.latitude must be a number from -90 to 90"),
            (with(place, "longitude", .double(-180.5)), false, "structured_location.longitude must be a number from -180 to 180"),
            (with(place, "longitude", nil), false, "structured_location.longitude is required when latitude is given"),
            (with(place, "latitude", nil), false, "structured_location.latitude is required when longitude is given")
        ]
        for (arguments, isTrigger, expected) in cases {
            let message = refusal {
                isTrigger ? try LocationArguments.locationTrigger(arguments) as Any : try LocationArguments.structuredLocation(arguments) as Any
            }
            XCTAssertTrue(message.contains(expected), "\(expected): \(message)")
        }
    }
}
