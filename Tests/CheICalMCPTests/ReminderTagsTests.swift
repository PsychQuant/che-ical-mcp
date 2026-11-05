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
    func testAdversarialLineIsReturnedUnchanged() throws {
        let input = String(repeating: "#a", count: 10_000) + " x"
        let start = Date()
        let result = ReminderTags.extract(from: input)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result.cleanNotes, input)
        XCTAssertTrue(result.tags.isEmpty)
        // #417: the linear-time bound judged through HostLoad (a loaded host can starve it). Last:
        // nothing above depends on it, so a skip here must not keep them from running.
        try HostLoad.live.checkWithinBound(elapsed, bound: 1, "Tag extraction of a 20,000-character line")
    }
}
