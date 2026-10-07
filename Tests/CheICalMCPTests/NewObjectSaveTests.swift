import EventKit
import XCTest
@testable import CheICalMCP

/// #261: on device (iCloud, 2026-10-07), a new reminder or reminder list whose save failed at
/// commit time stayed pending in the store, and the next successful save wrote it. The commit
/// failure was induced in the probe. `NewObjectSave` takes such an object back out before the
/// error leaves.
final class NewObjectSaveTests: XCTestCase {
    enum Failure: Error, Equatable { case commit, discard }

    func testASuccessfulSaveIsReturnedAndNothingIsDiscarded() throws {
        var calls: [String] = []
        let value = try NewObjectSave.run(save: { calls.append("save"); return "saved" },
                                          pending: { calls.append("pending"); return true },
                                          discard: { calls.append("discard") },
                                          logDiscardFailure: { _ in XCTFail("nothing to log") })
        XCTAssertEqual(value, "saved")
        XCTAssertEqual(calls, ["save"])
    }

    /// The discard runs once, after the failed save and before the error reaches the caller.
    func testAFailedSaveThatLeftTheObjectPendingIsDiscardedOnceBeforeItsErrorLeaves() {
        var calls: [String] = []
        XCTAssertThrowsError(try NewObjectSave.run(save: { () throws -> String in calls.append("save"); throw Failure.commit },
                                                   pending: { true },
                                                   discard: { calls.append("discard") },
                                                   logDiscardFailure: { _ in XCTFail("nothing to log") })) { error in
            XCTAssertEqual(error as? Failure, .commit)
            XCTAssertEqual(calls, ["save", "discard"], "discarded once, before the error left")
        }
    }

    /// A save refused before the store took the object in (on device: `isNew` stays true, as for
    /// a reminder without a list) leaves nothing pending, so nothing is removed and nothing logged.
    func testAFailedSaveThatLeftNothingPendingIsNotDiscarded() {
        XCTAssertThrowsError(try NewObjectSave.run(save: { () throws -> String in throw Failure.commit },
                                                   pending: { false },
                                                   discard: { XCTFail("nothing to discard") },
                                                   logDiscardFailure: { _ in XCTFail("nothing to log") })) { error in
            XCTAssertEqual(error as? Failure, .commit)
        }
    }

    /// A discard that fails is logged; the caller still gets the save's error.
    func testADiscardThatThrowsIsLoggedAndTheSaveErrorStillSurfaces() {
        var logged: [Failure] = []
        XCTAssertThrowsError(try NewObjectSave.run(save: { () throws -> String in throw Failure.commit },
                                                   pending: { true },
                                                   discard: { throw Failure.discard },
                                                   logDiscardFailure: { logged.append($0 as! Failure) })) { error in
            XCTAssertEqual(error as? Failure, .commit)
        }
        XCTAssertEqual(logged, [.discard])
    }

    /// Reminders and reminder lists kept a failed insert on device; events and event calendars
    /// did not.
    func testOnlyReminderTypesKeepAFailedInsert() {
        XCTAssertTrue(NewObjectSave.keepsFailedInsert(.reminder))
        XCTAssertFalse(NewObjectSave.keepsFailedInsert(.event))
    }

    /// The signal the save sites use: an object the store never took in reports `isNew`.
    func testANeverSavedReminderAndListReportIsNew() {
        let store = EKEventStore()
        XCTAssertTrue(EKReminder(eventStore: store).isNew)
        XCTAssertTrue(EKCalendar(for: .reminder, eventStore: store).isNew)
    }

    // MARK: - which save sites discard (source pins over every file in Sources/CheICalMCP)

    /// Every Swift file under Sources/CheICalMCP, comments removed and each run of whitespace
    /// collapsed to one space, so a reformat or a call split over lines reads the same.
    private func code() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheICalMCP")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        let joined = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        return joined
            .replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"//[^\n]*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Each match: the whole match and its groups, and where the match starts.
    private func matches(_ pattern: String, in text: String) throws -> [(groups: [String], start: String.Index)] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            ((0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" },
             Range(match.range, in: text)!.lowerBound)
        }
    }

    /// The code from `start` to the next method or switch case.
    private func segment(of text: String, at start: String.Index) -> String {
        let rest = text[text.index(after: start)...]
        let ends = [" func ", " case ."].compactMap { rest.range(of: $0)?.lowerBound }
        return String(text[start..<(ends.min() ?? text.endIndex)])
    }

    private func segment(of text: String, from start: String) throws -> String {
        segment(of: text, at: try XCTUnwrap(text.range(of: start), "missing \(start)").lowerBound)
    }

    func testEveryNewReminderIsSavedThroughSaveNewReminder() throws {
        let code = try code()
        let constructions = try matches(#"let (\w+) = EKReminder\(eventStore: "#, in: code)
        XCTAssertGreaterThanOrEqual(constructions.count, 2, "createReminder and the delete-undo recreate")
        for construction in constructions {
            let name = construction.groups[1]
            let body = segment(of: code, at: construction.start)
            XCTAssertEqual(try matches(#"try saveNewReminder\( ?\#(name) ?,"#, in: body).count, 1, body)
            XCTAssertEqual(try matches(#"\.save\( ?\#(name) ?,"#, in: body).count, 0, body)
        }
        let wrapper = try segment(of: code, from: "func saveNewReminder(")
        XCTAssertEqual(try matches(#"NewObjectSave\.run\( ?save: ?\{ ?try \w+\.save\( ?reminder ?, ?commit: ?true ?\) ?\} ?, ?pending: ?\{ ?!reminder\.isNew ?\} ?, ?discard: ?\{ ?try \w+\.remove\( ?reminder ?, ?commit: ?false ?\) ?\}"#,
                                       in: wrapper).count, 1, wrapper)
    }

    /// A new reminder list is discarded; a new event calendar is not (`keepsFailedInsert`).
    func testEveryNewCalendarIsSavedThroughNewObjectSave() throws {
        let code = try code()
        let constructions = try matches(#"let (\w+) = EKCalendar\(for: (\w+),"#, in: code)
        XCTAssertGreaterThanOrEqual(constructions.count, 1, "createCalendar")
        for construction in constructions {
            let (name, type) = (construction.groups[1], construction.groups[2])
            let body = segment(of: code, at: construction.start)
            XCTAssertEqual(try matches(#"saveCalendar\( ?\#(name) ?,"#, in: body).count, 1, body)
            XCTAssertEqual(try matches(#"NewObjectSave\.run\( ?save: ?\{ ?try \w+\.saveCalendar\( ?\#(name) ?, ?commit: ?true ?\) ?\} ?, ?pending: ?\{ ?NewObjectSave\.keepsFailedInsert\( ?\#(type) ?\) ?&& ?!\#(name)\.isNew ?\} ?, ?discard: ?\{ ?try \w+\.removeCalendar\( ?\#(name) ?, ?commit: ?false ?\) ?\}"#,
                                           in: body).count, 1, body)
        }
    }

    /// A change staged without committing is committed by whatever saves next. The only ones
    /// allowed are the reminder and reminder-list discards above: on device,
    /// `remove(event, span:, commit: false)` after a recurring event's failed save made the next
    /// save fail (EKCADErrorDomain 1001) and lose that event, and `reset()` drops every object
    /// the process holds.
    func testNothingElseIsStagedWithoutCommitting() throws {
        let code = try code()
        let staged = try matches(#"commit: ?false"#, in: code)
        let discards = try matches(#"discard: ?\{ ?try \w+\.(remove|removeCalendar)\( ?(reminder|calendar) ?, ?commit: ?false ?\) ?\}"#, in: code)
        XCTAssertEqual(staged.count, discards.count, "every commit: false is a reminder or list discard")
        XCTAssertEqual(discards.count, 2)
        XCTAssertEqual(try matches(#"span: ?[^,)]*, ?commit: ?false"#, in: code).count, 0)
        XCTAssertEqual(try matches(#"\.reset\(\)"#, in: code).count, 0)
    }
}
