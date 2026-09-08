import XCTest
@testable import CheICalMCP

final class ReminderTagsTests: XCTestCase {
    func testTrailingTagsPreserveOrderAndCleanNotes() {
        let result = ReminderTags.extract(from: "body #inline\n#one\t#中文 #one\n\n")
        XCTAssertEqual(result.cleanNotes, "body #inline")
        XCTAssertEqual(result.tags, ["one", "中文", "one"])
    }
    func testOnlyLastNonemptyLineCanBeTags() {
        XCTAssertEqual(ReminderTags.extract(from: "#tag\nbody").tags, [])
        XCTAssertEqual(ReminderTags.extract(from: "#").tags, [])
        XCTAssertEqual(ReminderTags.extract(from: "##").tags, ["#"])
    }
    func testAdversarialLineIsReturnedUnchanged() {
        let input = String(repeating: "#a", count: 10_000) + " x"
        let start = Date()
        let result = ReminderTags.extract(from: input)
        XCTAssertEqual(result.cleanNotes, input)
        XCTAssertTrue(result.tags.isEmpty)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}
