import EventKit
import XCTest
@testable import CheICalMCP

/// #261: on device (iCloud, 2026-10-07/08), a new reminder or reminder list whose save failed at
/// commit time stayed pending in the store, and the next successful save wrote it. The commit
/// failure was induced in the probe. `NewObjectSave` takes such an object back out before the
/// error leaves, unless a store made after the failure finds it (then the save committed).
final class NewObjectSaveTests: XCTestCase {
    enum Failure: Error, Equatable { case commit, discard }

    /// What removing a reminder that was never inserted threw on device (S10v, Gc ×3).
    let nothingPendingError = NSError(domain: EKErrorDomain, code: EKError.Code.calendarReadOnly.rawValue)

    private func name(_ outcome: NewObjectSave.Outcome) -> String {
        if case .discardFailed = outcome { return "discardFailed" }
        return "\(outcome)"
    }

    private func failedSave() throws -> String { throw Failure.commit }

    func testASuccessfulSaveIsReturnedAndNothingElseRuns() throws {
        var calls: [String] = []
        let value = try NewObjectSave.run(save: { calls.append("save"); return "saved" },
                                          committed: { calls.append("committed"); return false },
                                          discard: { calls.append("discard") },
                                          report: { calls.append("report \(self.name($0))") })
        XCTAssertEqual(value, "saved")
        XCTAssertEqual(calls, ["save"])
    }

    /// The default: a failed save that a new store cannot find is discarded once, after the
    /// check and before the error reaches the caller. Nothing is logged.
    func testAFailedSaveANewStoreCannotFindIsDiscardedOnceBeforeItsErrorLeaves() {
        var calls: [String] = []
        XCTAssertThrowsError(try NewObjectSave.run(save: { calls.append("save"); return try self.failedSave() },
                                                   committed: { calls.append("committed"); return false },
                                                   discard: { calls.append("discard") },
                                                   report: { calls.append("report \(self.name($0))") })) { error in
            XCTAssertEqual(error as? Failure, .commit)
            XCTAssertEqual(calls, ["save", "committed", "discard"])
        }
    }

    /// The one case with evidence that discarding is wrong: a new store finds the object, so
    /// the save committed and then threw. It is left in place and reported.
    func testAFailedSaveANewStoreFindsIsLeftInPlaceAndReported() {
        var calls: [String] = []
        XCTAssertThrowsError(try NewObjectSave.run(save: { calls.append("save"); return try self.failedSave() },
                                                   committed: { calls.append("committed"); return true },
                                                   discard: { calls.append("discard") },
                                                   report: { calls.append("report \(self.name($0))") })) { error in
            XCTAssertEqual(error as? Failure, .commit)
            XCTAssertEqual(calls, ["save", "committed", "report committedThenThrew"])
        }
    }

    /// No answer (the new store had no sources) is no evidence, so the object is discarded.
    func testAFailedSaveThatCouldNotBeCheckedIsDiscardedAndReported() {
        var calls: [String] = []
        XCTAssertThrowsError(try NewObjectSave.run(save: { calls.append("save"); return try self.failedSave() },
                                                   committed: { calls.append("committed"); return nil },
                                                   discard: { calls.append("discard") },
                                                   report: { calls.append("report \(self.name($0))") })) { error in
            XCTAssertEqual(error as? Failure, .commit)
            XCTAssertEqual(calls, ["save", "committed", "report unchecked", "discard"])
        }
    }

    /// A save refused before the store took the object in (a reminder with no list) leaves
    /// nothing pending, and the removal throws EKErrorDomain 6: reported as nothing pending,
    /// not as a failed discard.
    func testARemovalRefusedBecauseNothingWasPendingIsNotReportedAsAFailure() {
        var outcomes: [String] = []
        XCTAssertThrowsError(try NewObjectSave.run(save: { try self.failedSave() },
                                                   committed: { false },
                                                   discard: { throw self.nothingPendingError },
                                                   report: { outcomes.append(self.name($0)) })) { error in
            XCTAssertEqual(error as? Failure, .commit)
        }
        XCTAssertEqual(outcomes, ["nothingPending"])
    }

    /// Any other discard error is a failure (the object may still be written by the next
    /// save); the caller still gets the save's error.
    func testAnyOtherDiscardErrorIsReportedAsAFailureAndTheSaveErrorStillSurfaces() {
        var reported: [Error] = []
        XCTAssertThrowsError(try NewObjectSave.run(save: { try self.failedSave() },
                                                   committed: { false },
                                                   discard: { throw Failure.discard },
                                                   report: {
                                                       guard case .discardFailed(let error) = $0 else { return XCTFail("\($0)") }
                                                       reported.append(error)
                                                   })) { error in
            XCTAssertEqual(error as? Failure, .commit)
        }
        XCTAssertEqual(reported.map { $0 as? Failure }, [.discard])
    }

    func testOnlyEventKitError6CountsAsNothingPending() {
        XCTAssertTrue(NewObjectSave.isNothingPending(nothingPendingError))
        XCTAssertFalse(NewObjectSave.isNothingPending(NSError(domain: EKErrorDomain, code: EKError.Code.noCalendar.rawValue)))
        XCTAssertFalse(NewObjectSave.isNothingPending(NSError(domain: "EKCADErrorDomain", code: 6)))
        XCTAssertFalse(NewObjectSave.isNothingPending(Failure.discard))
    }

    /// Each note says what happened to the object; none reads as a failure. A failed discard has
    /// no note: it goes through the error sanitizer as `<handler>.discard(<id>) failed: …`.
    func testTheNotesSayWhatHappenedToTheObject() throws {
        let saved = try XCTUnwrap(NewObjectSave.note(for: .committedThenThrew, at: "h(id)"))
        XCTAssertTrue(saved.hasPrefix("h(id): ") && saved.contains("left in place") && saved.hasSuffix("\n"), saved)
        let unchecked = try XCTUnwrap(NewObjectSave.note(for: .unchecked, at: "h(id)"))
        XCTAssertTrue(unchecked.contains("removed"), unchecked)
        let nothing = try XCTUnwrap(NewObjectSave.note(for: .nothingPending, at: "h(id)"))
        XCTAssertTrue(nothing.contains("nothing to remove"), nothing)
        for note in [saved, unchecked, nothing] { XCTAssertFalse(note.contains("failed"), note) }
        XCTAssertNil(NewObjectSave.note(for: .discardFailed(Failure.discard), at: "h(id)"))
    }

    /// Reminders and reminder lists kept a failed insert on device; events and event calendars
    /// did not.
    func testOnlyReminderTypesKeepAFailedInsert() {
        XCTAssertTrue(NewObjectSave.keepsFailedInsert(.reminder))
        XCTAssertFalse(NewObjectSave.keepsFailedInsert(.event))
    }

    // MARK: - which save sites discard (source pins over every file in Sources/CheICalMCP)

    /// Swift source with comments removed and string literals emptied to `""`, so neither can
    /// hide or fake a match. Handles `"""` blocks and escapes; not raw strings (`#"…"#`), which
    /// Sources/CheICalMCP does not use. A string that runs past its line ends at the newline.
    private func stripped(_ source: String) -> String {
        let s = Array(source.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        func at(_ p: String) -> Bool {
            let q = Array(p.unicodeScalars)
            return i + q.count <= s.count && Array(s[i..<i + q.count]) == q
        }
        func skip(past p: String) {
            while i < s.count && !at(p) { i += 1 }
            i = min(s.count, i + p.unicodeScalars.count)
        }
        while i < s.count {
            if at("//") {
                while i < s.count && s[i] != "\n" { i += 1 }
            } else if at("/*") {
                i += 2; skip(past: "*/"); out.append(" ")
            } else if at("\"\"\"") {
                i += 3; skip(past: "\"\"\""); out.append(contentsOf: "\"\"".unicodeScalars)
            } else if s[i] == "\"" {
                i += 1
                while i < s.count && s[i] != "\"" && s[i] != "\n" { i += s[i] == "\\" ? 2 : 1 }
                if i < s.count && s[i] == "\"" { i += 1 }
                out.append(contentsOf: "\"\"".unicodeScalars)
            } else {
                out.append(s[i]); i += 1
            }
        }
        return String(out)
    }

    func testTheStripperDropsCommentsAndStringContentsAndKeepsCode() {
        let source = "let a = \"// not a comment\"; save(b) // gone\n/* gone */ keep(c)\nlet d = \"\"\"\nsave(e)\n\"\"\"\nlet f = \"x\\\"y\"; keep(g)"
        let out = stripped(source)
        XCTAssertTrue(out.contains("save(b)") && out.contains("keep(c)") && out.contains("keep(g)"), out)
        XCTAssertFalse(out.contains("gone") || out.contains("not a comment") || out.contains("save(e)") || out.contains("y\""), out)
    }

    /// Every Swift file under Sources/CheICalMCP, stripped, with each run of whitespace collapsed
    /// to one space, so a reformat or a call split over lines reads the same.
    private func code() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheICalMCP")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        return try files.map { stripped(try String(contentsOf: $0, encoding: .utf8)) }
            .joined(separator: "\n")
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

    /// The code from `start` to the next method or switch case. A `case .` inside a creating
    /// method (e.g. `if case .x`) would cut the segment short and fail the pin, not pass it.
    private func segment(of text: String, at start: String.Index) -> String {
        let rest = text[text.index(after: start)...]
        let ends = [" func ", " case ."].compactMap { rest.range(of: $0)?.lowerBound }
        return String(text[start..<(ends.min() ?? text.endIndex)])
    }

    private func segment(of text: String, from start: String) throws -> String {
        segment(of: text, at: try XCTUnwrap(text.range(of: start), "missing \(start)").lowerBound)
    }

    /// The `committed` check the save sites pass: a store made after the failure finds the object.
    private func freshCheck(_ lookup: String, _ id: String) -> String {
        #"committed: ?\{ ?NewObjectSave\.freshStoreFinds ?\{ ?\$0\.\#(lookup)\( ?withIdentifier: ?\#(id) ?\) ?!= ?nil ?\} ?\}"#
    }

    /// Every construction of a reminder, in any form (`let`, `var`, a type annotation, `.init`,
    /// inline), is a named local that is saved through `saveNewReminder` and nowhere else.
    func testEveryNewReminderIsSavedThroughSaveNewReminder() throws {
        let code = try code()
        let all = try matches(#"EKReminder(\.init)? ?\( ?eventStore:"#, in: code)
        let named = try matches(#"(?:let|var) (\w+)(?: ?: ?EKReminder)? = EKReminder(?:\.init)? ?\( ?eventStore:"#, in: code)
        XCTAssertEqual(all.count, named.count, "every EKReminder is built into a named local")
        XCTAssertGreaterThanOrEqual(named.count, 2, "createReminder and the delete-undo recreate")
        for construction in named {
            let name = construction.groups[1]
            let body = segment(of: code, at: construction.start)
            XCTAssertEqual(try matches(#"try saveNewReminder\( ?\#(name) ?,"#, in: body).count, 1, body)
            XCTAssertEqual(try matches(#"\.save\( ?\#(name) ?,"#, in: body).count, 0, body)
        }
        let wrapper = try segment(of: code, from: "func saveNewReminder(")
        XCTAssertEqual(try matches(#"NewObjectSave\.run\( ?save: ?\{ ?try \w+\.save\( ?reminder ?, ?commit: ?true ?\) ?\} ?, ?"#
                                   + freshCheck("calendarItem", #"reminder\.calendarItemIdentifier"#)
                                   + #" ?, ?discard: ?\{ ?try \w+\.remove\( ?reminder ?, ?commit: ?false ?\) ?\}"#,
                                   in: wrapper).count, 1, wrapper)
    }

    /// Every construction of a calendar is a named local; a reminder list goes through
    /// `NewObjectSave.run`, an event calendar is saved as before (`keepsFailedInsert`). Only this
    /// if/else shape passes: a new site written another way fails the pin.
    func testEveryNewCalendarIsSavedThroughNewObjectSave() throws {
        let code = try code()
        let all = try matches(#"EKCalendar(\.init)? ?\( ?for:"#, in: code)
        let named = try matches(#"(?:let|var) (\w+)(?: ?: ?EKCalendar)? = EKCalendar(?:\.init)? ?\( ?for: ?(\w+) ?,"#, in: code)
        XCTAssertEqual(all.count, named.count, "every EKCalendar is built into a named local, with its type in a variable")
        XCTAssertGreaterThanOrEqual(named.count, 1, "createCalendar")
        for construction in named {
            let (name, type) = (construction.groups[1], construction.groups[2])
            let body = segment(of: code, at: construction.start)
            XCTAssertEqual(try matches(#"saveCalendar\( ?\#(name) ?,"#, in: body).count, 2, body)
            XCTAssertEqual(try matches(#"if NewObjectSave\.keepsFailedInsert\( ?\#(type) ?\) ?\{ ?try NewObjectSave\.run\( ?save: ?\{ ?try \w+\.saveCalendar\( ?\#(name) ?, ?commit: ?true ?\) ?\} ?, ?"#
                                       + freshCheck("calendar", #"\#(name)\.calendarIdentifier"#)
                                       + #" ?, ?discard: ?\{ ?try \w+\.removeCalendar\( ?\#(name) ?, ?commit: ?false ?\) ?\} ?, ?report: ?\{[^}]*\} ?\) ?\} ?else ?\{ ?try \w+\.saveCalendar\( ?\#(name) ?, ?commit: ?true ?\) ?\}"#,
                                       in: body).count, 1, body)
        }
    }

    /// A change staged without committing is committed by whatever saves next. The only ones
    /// allowed are the reminder and reminder-list discards above: on device,
    /// `remove(event, span:, commit: false)` after a recurring event's failed save made the next
    /// save fail (EKCADErrorDomain 1001) and lose what that save wrote, and `reset()` drops every
    /// object the process holds. A commit flag passed as a variable is refused too, since the
    /// pin cannot read its value.
    func testNothingElseIsStagedWithoutCommitting() throws {
        let code = try code()
        let staged = try matches(#"commit: ?false"#, in: code)
        let discards = try matches(#"discard: ?\{ ?try \w+\.(?:remove\( ?reminder|removeCalendar\( ?calendar) ?, ?commit: ?false ?\) ?\}"#, in: code)
        XCTAssertEqual(staged.count, discards.count, "every commit: false is a reminder or list discard")
        XCTAssertEqual(discards.count, 2)
        XCTAssertEqual(try matches(#"commit: ?(?!true\b|false\b)[^ ,)]"#, in: code).count, 0, "commit flags are literals")
        XCTAssertEqual(try matches(#"span: ?[^,)]*, ?commit: ?false"#, in: code).count, 0)
        XCTAssertEqual(try matches(#"\.reset\( ?\)"#, in: code).count, 0)
    }
}
