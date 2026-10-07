import XCTest
@testable import CheICalMCP

/// #261: a new reminder or reminder list whose save fails stays pending in the server's store,
/// and the next successful save, from any tool, writes it (checked on device, iCloud,
/// 2026-10-07). `NewObjectSave` takes it back out before the error leaves.
final class NewObjectSaveTests: XCTestCase {
    enum Failure: Error, Equatable { case commit, discard }

    func testASuccessfulSaveIsReturnedAndNothingIsDiscarded() throws {
        var calls: [String] = []
        let value = try NewObjectSave.run(save: { calls.append("save"); return "saved" },
                                          discard: { calls.append("discard") },
                                          logDiscardFailure: { _ in XCTFail("nothing to log") })
        XCTAssertEqual(value, "saved")
        XCTAssertEqual(calls, ["save"])
    }

    /// The discard runs once, after the failed save and before the error reaches the caller.
    func testAFailedSaveIsDiscardedOnceBeforeItsErrorLeaves() {
        var calls: [String] = []
        XCTAssertThrowsError(try NewObjectSave.run(save: { () throws -> String in calls.append("save"); throw Failure.commit },
                                                   discard: { calls.append("discard") },
                                                   logDiscardFailure: { _ in XCTFail("nothing to log") })) { error in
            XCTAssertEqual(error as? Failure, .commit)
            XCTAssertEqual(calls, ["save", "discard"], "discarded once, before the error left")
        }
    }

    /// On device, `remove(_:commit: false)` of a reminder that failed validation (never inserted)
    /// throws. That error goes to the log; the caller still gets the save's error.
    func testADiscardThatThrowsIsLoggedAndTheSaveErrorStillSurfaces() {
        var logged: [Failure] = []
        XCTAssertThrowsError(try NewObjectSave.run(save: { () throws -> String in throw Failure.commit },
                                                   discard: { throw Failure.discard },
                                                   logDiscardFailure: { logged.append($0 as! Failure) })) { error in
            XCTAssertEqual(error as? Failure, .commit)
        }
        XCTAssertEqual(logged, [.discard])
    }

    // MARK: - which save sites discard (source pins)

    private func managerSource() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let path = repoRoot.appendingPathComponent("Sources/CheICalMCP/EventKit/EventKitManager.swift")
        return try String(contentsOf: path, encoding: .utf8)
    }

    /// The text from `start` up to the first `end` after it (`"\n    }\n"`: the end of a method).
    private func slice(_ source: String, from start: String, to end: String) throws -> Substring {
        let lower = try XCTUnwrap(source.range(of: start), "missing \(start)")
        let upper = source.range(of: end, range: lower.upperBound..<source.endIndex)?.lowerBound ?? source.endIndex
        return source[lower.lowerBound..<upper]
    }

    func testANewReminderIsSavedThroughTheDiscardInCreateAndInDeleteUndo() throws {
        let source = try managerSource()
        for body in [try slice(source, from: "func createReminder(", to: "\n    }\n"),
                     try slice(source, from: "case .deleteReminder(let snapshot):", to: "\n        case .")] {
            XCTAssertTrue(body.contains("try saveNewReminder(reminder"), String(body))
            XCTAssertFalse(body.contains("eventStore.save(reminder, commit: true)"), String(body))
        }
        let wrapper = try slice(source, from: "func saveNewReminder(", to: "\n    }\n")
        XCTAssertTrue(wrapper.contains("NewObjectSave.run"), String(wrapper))
        XCTAssertTrue(wrapper.contains("remove(reminder, commit: false)"), String(wrapper))
    }

    /// A reminder list is discarded; an event calendar is not (EventKit drops it itself).
    func testANewCalendarIsDiscardedOnlyWhenItIsAReminderList() throws {
        let body = try slice(try managerSource(), from: "func createCalendar(", to: "\n    }\n")
        XCTAssertTrue(body.contains("NewObjectSave.run"), String(body))
        XCTAssertTrue(body.contains("if entityType == .reminder { try eventStore.removeCalendar(calendar, commit: false) }"),
                      String(body))
    }

    /// Events get no discard: EventKit drops a failed new event itself, and on device
    /// `remove(event, span:, commit: false)` after a recurring event's failed save made the next
    /// save fail (EKCADErrorDomain 1001) and lose that event.
    func testNoEventIsRemovedWithoutCommitting() throws {
        let offending = try managerSource().split(separator: "\n")
            .filter { $0.contains("span:") && $0.contains("commit: false") && !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        XCTAssertEqual(offending, [])
    }
}
