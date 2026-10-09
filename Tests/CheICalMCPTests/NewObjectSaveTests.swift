import EventKit
import XCTest
@testable import CheICalMCP

/// #261: on device (iCloud, 2026-10-07/08), a new reminder or reminder list whose save failed at
/// commit time stayed pending in the store, and the next successful save wrote it. The commit
/// failure was induced in the probe. `NewObjectSave` takes such an object back out before the
/// error leaves, unless a store made after the failure finds it (then the save committed).
final class NewObjectSaveTests: XCTestCase {
    enum Failure: Error, Equatable { case commit, discard }

    /// The one pair seen on device for a save refused before the store took the object in: a
    /// reminder with no list (EKErrorDomain 1), whose removal threw EKErrorDomain 6.
    let refusedNoList = NSError(domain: EKErrorDomain, code: EKError.Code.noCalendar.rawValue)
    let removalReadOnly = NSError(domain: EKErrorDomain, code: EKError.Code.calendarReadOnly.rawValue)

    private func name(_ outcome: NewObjectSave.Outcome) -> String {
        switch outcome {
        case .committedThenThrew: return "committedThenThrew"
        case .committedButDiffers: return "committedButDiffers"
        case .unchecked: return "unchecked"
        case .nothingPending: return "nothingPending"
        case .discardFailed: return "discardFailed"
        }
    }

    /// Same domain and code (a Swift error is compared through its NSError bridge).
    private func code(_ error: Error?) -> String? {
        error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" }
    }

    /// Runs the helper with closures that record each call; `report` records the outcome by name.
    private func run(save: @escaping () throws -> Void = { throw Failure.commit }, committed: NewObjectSave.Found?,
                     discard: @escaping () throws -> Void = {}) -> (calls: [String], error: Error?, differing: [String]) {
        var calls: [String] = []
        do {
            let differing = try NewObjectSave.run(save: { calls.append("save"); try save() },
                                                  committed: { calls.append("committed"); return committed },
                                                  discard: { calls.append("discard"); try discard() },
                                                  report: { calls.append("report \(self.name($0))") })
            return (calls, nil, differing)
        } catch {
            return (calls, error, [])
        }
    }

    func testASuccessfulSaveRunsNothingElse() {
        let result = run(save: {}, committed: .absent)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.calls, ["save"])
        XCTAssertEqual(result.differing, [])
    }

    /// The default: a failed save that a new store cannot find is discarded once, after the
    /// check and before the error reaches the caller. Nothing is logged.
    func testAFailedSaveANewStoreCannotFindIsDiscardedOnceBeforeItsErrorLeaves() {
        let result = run(committed: .absent)
        XCTAssertEqual(result.error as? Failure, .commit)
        XCTAssertEqual(result.calls, ["save", "committed", "discard"])
    }

    /// A new store finds the object as it was saved (`Found.saved`): the save committed and then
    /// threw. The object is kept and `run` returns, so every caller takes its success path (the
    /// create's result and undo record, the refresh mark; delete-undo consumes its record).
    /// Reported once, with the save's error, and nothing removed.
    func testAFailedSaveANewStoreFindsAsSavedIsKeptAndTheCallSucceeds() throws {
        let result = run(committed: .saved)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.calls, ["save", "committed", "report committedThenThrew"])
        XCTAssertEqual(result.differing, [], "nothing to note")
        var reported: [NewObjectSave.Outcome] = []
        _ = try NewObjectSave.run(save: { throw Failure.commit }, committed: { .saved }, discard: { XCTFail("discarded") },
                                  report: { reported.append($0) })
        guard case .committedThenThrew(let save) = try XCTUnwrap(reported.first) else { return XCTFail("\(reported)") }
        XCTAssertEqual(save as? Failure, .commit)
    }

    /// A new store finds an item under the identifier, but a compared field differs (a partial
    /// write, or an edit made elsewhere between the commit and the check). The item counts as
    /// saved too: it is kept and `run` returns, so every caller takes its success path (the
    /// create's result and undo entry, delete-undo consumes its record), and `run` returns the
    /// names of the differing fields for the caller to report. Nothing is removed.
    func testAFoundItemThatDiffersCountsAsSavedAndItsFieldsAreReturned() throws {
        let result = run(committed: .differs(["due", "title"]))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.calls, ["save", "committed", "report committedButDiffers"])
        XCTAssertEqual(result.differing, ["due", "title"])
        var reported: [NewObjectSave.Outcome] = []
        _ = try NewObjectSave.run(save: { throw Failure.commit }, committed: { .differs(["list"]) },
                                  discard: { XCTFail("discarded") }, report: { reported.append($0) })
        guard case .committedButDiffers(let fields, let save) = try XCTUnwrap(reported.first) else { return XCTFail("\(reported)") }
        XCTAssertEqual(fields, ["list"])
        XCTAssertEqual(save as? Failure, .commit)
    }

    /// What the caller says about differing fields, all through one formatter
    /// (`differingFieldsNote`): a create response gets `store_differs` (the names) and a `note`;
    /// an undo message gets the note after a dash; a batch undo lists its restored members with
    /// their notes, from the names each member returned. Names only, never values. Nothing when
    /// nothing differs.
    func testTheDifferingFieldsAreNamedInTheResponseAndTheUndoMessage() throws {
        XCTAssertNil(NewObjectSave.differingFieldsNote([]))
        XCTAssertEqual(NewObjectSave.differingFieldsNote(["due", "title"]), "the store holds a different due, title; check it")
        XCTAssertTrue(NewObjectSave.responseFields([]).isEmpty)
        let fields = NewObjectSave.responseFields(["due", "title"])
        XCTAssertEqual(fields["store_differs"] as? [String], ["due", "title"])
        XCTAssertEqual(fields["note"] as? String, "Saved, but the store holds a different due, title; check it. Creating it again with the same parameters may make a second copy.")
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(NewObjectSave.undoSuffix([]), "")
        XCTAssertEqual(NewObjectSave.undoSuffix(["title"]), " — the store holds a different title; check it")
        // The batch undo's entries (PR #282, `UndoRestoredDifference.sentences`): one per member
        // with differing fields, in #280's words.
        XCTAssertEqual(UndoRestoredDifference.sentences([UndoRestoredDifference(title: "a", storeDiffers: []),
                                                         UndoRestoredDifference(title: "b", storeDiffers: ["due"]),
                                                         UndoRestoredDifference(title: "c", storeDiffers: ["title", "url"])]),
                       " Restored reminder 'b' — the store holds a different due; check it. Restored reminder 'c' — the store holds a different title, url; check it.")
        XCTAssertEqual(UndoRestoredDifference.sentences([UndoRestoredDifference(title: "a", storeDiffers: [])]), "")
        XCTAssertEqual(UndoRestoredDifference.sentences([]), "")
    }

    /// A title is set by the user or by whoever shares the list, so it can hold the note's own
    /// wording, quotes and a fake next entry. Shown through `undoShownTitle` (quotes replaced,
    /// control characters dropped, capped), it stays inside its own quotes: the single message of
    /// a reminder restored as written carries no note outside them, and a batch entry for a member
    /// that does differ stays one entry on one line.
    func testATitleCannotForgeOrSplitTheNote() {
        let forged = "x' — the store holds a different title; check it\nrestored reminder 'y' — the store holds a different due; check it"
        let single = EventKitManager.restoredReminderMessage((title: forged, storeDiffers: []))
        XCTAssertTrue(single.hasPrefix("Undone: restored reminder '") && single.hasSuffix("'"), single)
        XCTAssertEqual(single.filter { $0 == "'" }.count, 2, "only the message's own quotes: \(single)")
        XCTAssertFalse(single.contains("\n"), single)
        let noted = EventKitManager.restoredReminderMessage((title: forged, storeDiffers: ["due"]))
        XCTAssertEqual(noted.filter { $0 == "'" }.count, 2, noted)
        XCTAssertTrue(noted.hasSuffix("' — the store holds a different due; check it"), noted)
        let batch = UndoRestoredDifference.sentences([UndoRestoredDifference(title: forged, storeDiffers: ["title"])])
        XCTAssertFalse(batch.contains("\n"), "undoShownTitle drops the line break: \(batch)")
        XCTAssertEqual(batch.filter { $0 == "'" }.count, 2, batch)
        XCTAssertEqual(batch.components(separatedBy: "Restored reminder '").count - 1, 1, batch)
    }

    /// The names a `store_differs` can hold are exactly the keys `Fields` compares, which the tool
    /// descriptions list.
    /// PR #298 verify round 3: a date-only reminder written through setDueDay compares equal to the
    /// copy a store hands back (due without a time or zone, start at 00:00 of the day, as on device),
    /// so a date-only create found after a save that threw counts as saved, not as differing.
    func testADateOnlyReminderComparesEqualToTheStoredCopy() {
        let store = EKEventStore()
        let written = EKReminder(eventStore: store)
        _ = ReminderDateSync.setDueDay(written, to: DateComponents(year: 2026, month: 10, day: 18))
        let stored = EKReminder(eventStore: store)
        stored.dueDateComponents = DateComponents(year: 2026, month: 10, day: 18)
        stored.startDateComponents = DateComponents(year: 2026, month: 10, day: 18, hour: 0, minute: 0)
        let found = NewObjectSave.check(NewObjectSave.Fields(reminder: written), against: NewObjectSave.Fields(reminder: stored))
        guard case .saved = found else { return XCTFail("\(found)") }
    }

    func testTheFieldNamesAreTheComparedKeys() {
        let store = EKEventStore()
        XCTAssertEqual(Set(NewObjectSave.Fields(reminder: EKReminder(eventStore: store)).values.keys), Set(NewObjectSave.reminderFieldNames))
        XCTAssertEqual(Set(NewObjectSave.Fields(list: EKCalendar(for: .reminder, eventStore: store)).values.keys), Set(NewObjectSave.listFieldNames))
    }

    /// The comparison: nothing under the identifier is `absent`; the same values are `saved`; any
    /// value that differs, or is present on one side only, is named in `differs`, sorted.
    func testTheCheckNamesEveryFieldThatDiffers() {
        let saved = NewObjectSave.Fields(["title": "a", "list": "L1", "due": "2030 1 15 10 0"])
        XCTAssertEqual(NewObjectSave.check(saved, against: nil), .absent)
        XCTAssertEqual(NewObjectSave.check(saved, against: saved), .saved)
        XCTAssertEqual(NewObjectSave.check(saved, against: .init(["title": "b", "list": "L1", "due": "2030 1 15 10 0"])), .differs(["title"]))
        XCTAssertEqual(NewObjectSave.check(saved, against: .init(["title": "a", "list": "L2", "due": "2030 1 15 11 0"])), .differs(["due", "list"]))
        XCTAssertEqual(NewObjectSave.check(saved, against: .init(["title": "a", "list": "L1"])), .differs(["due"]))
        XCTAssertEqual(NewObjectSave.check(saved, against: .init(["title": "a", "list": "L1", "due": "2030 1 15 10 0", "notes": "n"])), .differs(["notes"]),
                       "a field only the store's copy has")
    }

    /// What is compared, read from in-memory objects (one store, nothing saved). A reminder: its
    /// title, list (by identifier), notes, priority, completion, URL, start and due date to the
    /// minute (a date-only start reads as 00:00, which is how the store hands one back; a
    /// date-only due has no time), the due date's time zone, and how many alarms and recurrence
    /// rules it has. A list: its title and account. A missing value reads as empty.
    func testTheFieldsAreTheOnesTheSaveWritesThatReadBackSimply() {
        let store = EKEventStore()
        let reminder = EKReminder(eventStore: store)
        reminder.title = "a"
        XCTAssertEqual(NewObjectSave.Fields(reminder: reminder), .init([
            "title": "a", "list": "", "notes": "", "priority": "0", "completion": "open", "url": "",
            "start": "", "due": "", "due time zone": "", "alarm count": "0", "recurrence rule count": "0"]))
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = "l"
        reminder.calendar = list
        reminder.notes = "n"
        reminder.priority = 5
        reminder.isCompleted = true
        reminder.url = URL(string: "https://example.com/x")
        var due = DateComponents(year: 2030, month: 1, day: 15, hour: 10, minute: 5, second: 30)
        due.timeZone = TimeZone(identifier: "Asia/Taipei")
        reminder.dueDateComponents = due
        reminder.addAlarm(EKAlarm(relativeOffset: -900))
        reminder.addAlarm(EKAlarm(relativeOffset: -60))
        reminder.addRecurrenceRule(EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil))
        XCTAssertEqual(NewObjectSave.Fields(reminder: reminder), .init([
            "title": "a", "list": list.calendarIdentifier, "notes": "n", "priority": "5", "completion": "completed",
            "url": "https://example.com/x", "start": "2030 1 15 10 5", "due": "2030 1 15 10 5", "due time zone": "Asia/Taipei",
            "alarm count": "2", "recurrence rule count": "1"]), "EventKit gives a reminder without a start one equal to a due written to it (#235)")
        XCTAssertFalse(list.calendarIdentifier.isEmpty)
        // The time zone is read as EventKit reports it after the writes: a date-only start written
        // after the due leaves the reminder floating (#251, in memory), and the field follows.
        reminder.startDateComponents = DateComponents(year: 2030, month: 1, day: 14)
        XCTAssertEqual(NewObjectSave.Fields(reminder: reminder).values["start"], "2030 1 14 0 0")
        XCTAssertEqual(NewObjectSave.Fields(reminder: reminder).values["due time zone"], reminder.dueDateComponents?.timeZone?.identifier ?? "")
        reminder.startDateComponents = DateComponents(year: 2030, month: 1, day: 14, hour: 9, minute: 30)
        reminder.dueDateComponents = DateComponents(year: 2030, month: 1, day: 15)
        XCTAssertEqual(NewObjectSave.Fields(reminder: reminder).values["start"], "2030 1 14 9 30")
        XCTAssertEqual(NewObjectSave.Fields(reminder: reminder).values["due"], "2030 1 15 - -")
        XCTAssertEqual(NewObjectSave.Fields(reminder: reminder).values["due time zone"], "")
        XCTAssertEqual(NewObjectSave.Fields(list: list), .init(["title": "l", "account": ""]))
    }

    /// No answer (the new store had no sources) is no evidence, so the object is discarded, and
    /// `unchecked` is reported only once the removal has run without an error.
    func testAFailedSaveThatCouldNotBeCheckedIsDiscardedThenReported() {
        let result = run(committed: nil)
        XCTAssertEqual(result.error as? Failure, .commit)
        XCTAssertEqual(result.calls, ["save", "committed", "discard", "report unchecked"])
    }

    /// When the check gave no answer and the removal failed, the failure is the one report: no
    /// line claims a removal that did not happen.
    func testAnUncheckedSaveWhoseRemovalFailsReportsOnlyTheFailure() {
        let result = run(committed: nil, discard: { throw Failure.discard })
        XCTAssertEqual(result.error as? Failure, .commit)
        XCTAssertEqual(result.calls, ["save", "committed", "discard", "report discardFailed"])
    }

    /// The probed pair: a reminder refused for having no list (save EKErrorDomain 1), whose
    /// removal throws EKErrorDomain 6, left nothing pending. Reported once, as nothing pending,
    /// with or without an answer from the new store.
    func testTheProbedRefusalWithItsRemovalErrorIsReportedAsNothingPending() {
        for committed in [.absent, nil] as [NewObjectSave.Found?] {
            let result = run(save: { throw self.refusedNoList }, committed: committed, discard: { throw self.removalReadOnly })
            XCTAssertEqual((result.error as NSError?)?.code, EKError.Code.noCalendar.rawValue)
            XCTAssertEqual(result.calls, ["save", "committed", "discard", "report nothingPending"], "\(String(describing: committed))")
        }
    }

    /// EKErrorDomain 6 from the removal after any other save error is a failed discard, reported
    /// with both errors: an induced commit failure, a list with no source (removed without an
    /// error on device, so it has no pair), a store without sources (EKErrorDomain 29).
    func testTheRemovalErrorAfterAnyOtherSaveErrorIsAFailedDiscardWithBothErrors() throws {
        let saves: [Error] = [Failure.commit,
                              NSError(domain: EKErrorDomain, code: EKError.Code.calendarHasNoSource.rawValue),
                              NSError(domain: EKErrorDomain, code: EKError.Code.eventStoreNotAuthorized.rawValue),
                              NSError(domain: "EKCADErrorDomain", code: 1010)]
        for saveError in saves {
            var reported: [NewObjectSave.Outcome] = []
            XCTAssertThrowsError(try NewObjectSave.run(save: { throw saveError }, committed: { .absent },
                                                       discard: { throw self.removalReadOnly },
                                                       report: { reported.append($0) }))
            XCTAssertEqual(reported.count, 1, "\(saveError)")
            guard case .discardFailed(let save, let discard) = try XCTUnwrap(reported.first) else { return XCTFail("\(reported)") }
            XCTAssertEqual(code(save), code(saveError))
            XCTAssertEqual(code(discard), code(removalReadOnly))
        }
    }

    /// Any other removal error, after the probed refusal too, is a failed discard (the object may
    /// still be written by the next save); the caller still gets the save's error.
    func testAnyOtherRemovalErrorIsAFailedDiscardAndTheSaveErrorStillSurfaces() {
        for saveError in [refusedNoList, Failure.commit] as [Error] {
            var reported: [String] = []
            XCTAssertThrowsError(try NewObjectSave.run(save: { throw saveError }, committed: { .absent },
                                                       discard: { throw Failure.discard },
                                                       report: {
                                                           guard case .discardFailed(_, let discard) = $0 else { return XCTFail("\($0)") }
                                                           reported.append("\(discard)")
                                                       })) { error in
                XCTAssertEqual(self.code(error), self.code(saveError))
            }
            XCTAssertEqual(reported, ["discard"])
        }
    }

    func testOnlyTheProbedPairCountsAsNothingPending() {
        XCTAssertEqual([EKError.Code.noCalendar.rawValue, EKError.Code.calendarReadOnly.rawValue,
                        EKError.Code.calendarHasNoSource.rawValue, EKError.Code.eventStoreNotAuthorized.rawValue], [1, 6, 14, 29])
        XCTAssertTrue(NewObjectSave.isNothingPending(save: refusedNoList, discard: removalReadOnly))
        let noSource = NSError(domain: EKErrorDomain, code: EKError.Code.calendarHasNoSource.rawValue)
        XCTAssertFalse(NewObjectSave.isNothingPending(save: noSource, discard: removalReadOnly))
        XCTAssertFalse(NewObjectSave.isNothingPending(save: Failure.commit, discard: removalReadOnly))
        XCTAssertFalse(NewObjectSave.isNothingPending(save: refusedNoList, discard: NSError(domain: EKErrorDomain, code: EKError.Code.noCalendar.rawValue)))
        XCTAssertFalse(NewObjectSave.isNothingPending(save: refusedNoList, discard: NSError(domain: "EKCADErrorDomain", code: 6)))
        XCTAssertFalse(NewObjectSave.isNothingPending(save: NSError(domain: "EKCADErrorDomain", code: 1), discard: removalReadOnly))
        XCTAssertFalse(NewObjectSave.isNothingPending(save: refusedNoList, discard: Failure.discard))
    }

    /// Each outcome has one line, which says what happened to the object; the stderr format is
    /// pinned word for word. Only a failed discard reads as a failure, and its line names both
    /// errors by domain and code.
    func testEachOutcomeHasOneLineThatSaysWhatHappened() {
        let commitFailure = NSError(domain: "EKCADErrorDomain", code: 1010)
        XCTAssertEqual(NewObjectSave.note(for: .committedThenThrew(save: commitFailure), handler: "h", identifier: "id"),
                       "h(id): the save threw EKCADErrorDomain 1010, but a new store finds the item as it was saved, so it was saved; it is kept and the call succeeds")
        XCTAssertEqual(NewObjectSave.note(for: .committedButDiffers(fields: ["due", "title"], save: commitFailure), handler: "h", identifier: "id"),
                       "h(id): the save threw EKCADErrorDomain 1010, and a new store finds the item, but its due, title differ from what was written (a partial write or an edit made elsewhere); it is kept and the call succeeds with a note naming them")
        XCTAssertEqual(NewObjectSave.note(for: .unchecked, handler: "h", identifier: "id"),
                       "h(id): the save threw and a new store could not be read, so whether it was saved is unknown; it was removed from the store without committing")
        XCTAssertEqual(NewObjectSave.note(for: .nothingPending, handler: "h", identifier: "id"),
                       "h(id): the save was refused before the store took the item in; nothing to remove")
        XCTAssertEqual(NewObjectSave.note(for: .discardFailed(save: NSError(domain: "EKCADErrorDomain", code: 1010), discard: removalReadOnly),
                                          handler: "h", identifier: "id"),
                       "h.discard(id) failed: the save threw EKCADErrorDomain 1010 and removing the item without committing threw \(EKErrorDomain) 6; the next save by any tool may write it")
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
    /// Sources/CheICalMCP does not use, nor an interpolation that holds a quote
    /// (`"\(a ?? "x")"`), whose inner quote ends the string early. A string that runs past its
    /// line ends at the newline, so that misreading stays on its line; no such line holds pinned
    /// code (`testNoPinnedCodeSharesALineWithAnInterpolatedQuote`).
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

    /// The code from `start` to the next function or the next switch arm. A segment cut short
    /// fails the pin; it never passes it. A `case .` right after the word `if`, `guard`, `while` or
    /// `for`, or after a comma in a condition list, is a pattern match in the same scope, not an
    /// arm (#267: createReminder's `if case .day(let day)? = due` cut the segment before its save).
    /// The word must stand alone: an identifier that only ends in one of them does not count
    /// (PR #298 verify rounds 1 and 2).
    private static let patternMatchContext = try! NSRegularExpression(pattern: #"(?:(?:^|[^A-Za-z0-9_])(?:if|guard|while|for)|,)$"#)

    private func segment(of text: String, at start: String.Index) -> String {
        let rest = text[text.index(after: start)...]
        let function = rest.range(of: " func ")?.lowerBound
        let arm = rest.ranges(of: " case .").map(\.lowerBound).first { index in
            let before = String(rest[..<index].suffix(8))
            return Self.patternMatchContext.firstMatch(in: before, range: NSRange(before.startIndex..., in: before)) == nil
        }
        return String(text[start..<([function, arm].compactMap { $0 }.min() ?? text.endIndex)])
    }

    /// The body of the function declared at `declaration`, from its opening brace to the one that
    /// matches it, so a pin on it does not depend on what is declared after it. Braces in comments
    /// and strings are gone after `stripped`.
    private func body(of declaration: String, in text: String) throws -> String {
        let after = try XCTUnwrap(text.range(of: declaration), "missing \(declaration)").upperBound
        let open = try XCTUnwrap(text[after...].firstIndex(of: "{"), "no body after \(declaration)")
        var depth = 0
        for index in text[open...].indices {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" { depth -= 1 }
            if depth == 0 { return String(text[open...index]) }
        }
        XCTFail("unbalanced braces after \(declaration)")
        return ""
    }

    private func segment(of text: String, from start: String) throws -> String {
        segment(of: text, at: try XCTUnwrap(text.range(of: start), "missing \(start)").lowerBound)
    }

    /// The `committed` check the save sites pass: a store made after the failure looks the object
    /// up and compares it (`reminderCheck` / `listCheck`, pinned in
    /// `testTheCheckReadsANewStoreOnlyAndComparesItsCopy`).
    private func freshCheck(_ check: String, _ object: String) -> String {
        #"committed: ?\{ ?NewObjectSave\.freshStoreFinds\( ?NewObjectSave\.\#(check)\( ?\#(object) ?\) ?\) ?\}"#
    }

    /// The `report` closure the save sites pass: every outcome goes to `logNewObjectOutcome`.
    private func report(_ handler: String, _ id: String) -> String {
        #"report: ?\{ ?Self\.logNewObjectOutcome\( ?handler: ?\#(handler) ?, ?identifier: ?\#(id) ?, ?\$0 ?\) ?\}"#
    }

    /// Every construction of a reminder, in any form (`let`, `var`, a type annotation, `.init`,
    /// inline, inside a closure), is accounted for. Three forms pass, and nothing else does:
    /// - bound to a local: `let r = EKReminder(eventStore: s)`;
    /// - built in a closure whose result a call returns into a local, as the delete-undo arm does
    ///   since #277 (`let r = try await applyReminderSnapshot(…, into: { EKReminder(eventStore: s) })`),
    ///   so the reminder is created after the lists are read;
    /// - built inline as the argument of `saveNewReminder`.
    /// Each local is then saved through `saveNewReminder` once and never with a bare `.save`.
    func testEveryNewReminderIsSavedThroughSaveNewReminder() throws {
        let code = try code()
        let build = #"EKReminder(?:\.init)? ?\( ?eventStore: ?\w+ ?\)"#
        let all = try matches(#"EKReminder(\.init)? ?\( ?eventStore:"#, in: code)
        let direct = try matches(#"(?:let|var) (\w+)(?: ?: ?EKReminder)? = "# + build, in: code)
        // The call's other arguments may hold balanced parentheses but no braces or semicolons, so
        // a match cannot run from one statement into the next.
        let viaClosure = try matches(#"(?:let|var) (\w+)(?: ?: ?EKReminder)? = (?:try )?(?:await )?\w+\((?:[^(){};]|\([^(){};]*\))*\{ ?"# + build + #" ?\} ?\)"#, in: code)
        let inline = try matches(#"try saveNewReminder\( ?"# + build + #" ?,"#, in: code)
        XCTAssertEqual(all.count, direct.count + viaClosure.count + inline.count, "every EKReminder is built into a local or into saveNewReminder")
        XCTAssertGreaterThanOrEqual(direct.count + viaClosure.count, 2, "createReminder and the delete-undo recreate")
        for construction in direct + viaClosure {
            let name = construction.groups[1]
            let body = segment(of: code, at: construction.start)
            XCTAssertEqual(try matches(#"try saveNewReminder\( ?\#(name) ?,"#, in: body).count, 1, body)
            XCTAssertEqual(try matches(#"\.save\( ?\#(name) ?,"#, in: body).count, 0, body)
        }
        let wrapper = try segment(of: code, from: "func saveNewReminder(")
        XCTAssertEqual(try matches(#"NewObjectSave\.run\( ?save: ?\{ ?try \w+\.save\( ?reminder ?, ?commit: ?true ?\) ?\} ?, ?"#
                                   + freshCheck("reminderCheck", "reminder")
                                   + #" ?, ?discard: ?\{ ?try \w+\.remove\( ?reminder ?, ?commit: ?false ?\) ?\} ?, ?"#
                                   + report(#"handler"#, #"reminder\.calendarItemIdentifier"#) + #" ?\) ?\}$"#,
                                   in: try body(of: "func saveNewReminder(", in: code)).count, 1, wrapper)
        // When `saveNewReminder` returns, after a save or after a save that threw but that a new
        // store finds, each caller goes on to its success path, with nothing caught in between:
        // create_reminder marks the store for a refresh, builds the result and records the undo
        // entry; delete-undo marks the refresh and reports the restore (its record is consumed).
        // The names of fields the store holds differently travel with the success: into the
        // create's result, and onto the undo message.
        let create = try body(of: "func createReminder( title:", in: code)
        XCTAssertEqual(try matches(#"let storeDiffers = try saveNewReminder\( ?reminder ?, ?handler: ?"" ?\) ?markNeedsRefresh\( ?\) ?let result = CreateReminderResult\( ?reminder: ?ReminderWriteSnapshot\( ?from: ?reminder ?\) ?, ?isDuplicate: ?false ?, ?storeDiffers: ?storeDiffers ?\) ?let createdID = result\.reminder\.calendarItemIdentifier ?await CalendarUndoManager\.shared\.record\( ?\.createReminder\( ?id: ?createdID ?,"#,
                                   in: create).count, 1, create)
        // Delete-undo, single and in a batch, goes through one helper that returns the names as
        // data; the single arm turns them into its message, the batch arm collects them per member.
        let undoArm = try body(of: "func restoreDeletedReminder(_ snapshot: ReminderSnapshot) async throws -> (title: String, storeDiffers: [String])", in: code)
        XCTAssertEqual(try matches(#"^\{ ?let reminder = try await applyReminderSnapshot\( ?snapshot ?, ?for: ?\.recreateDeleted ?, ?into: ?\{ ?EKReminder\( ?eventStore: ?eventStore ?\) ?\} ?\) ?let storeDiffers = try saveNewReminder\( ?reminder ?, ?handler: ?"" ?\) ?markNeedsRefresh\( ?\) ?return \( ?snapshot\.title ?, ?storeDiffers ?\) ?\}$"#, in: undoArm).count, 1, undoArm)
        let message = try body(of: "static func restoredReminderMessage(_ restored: (title: String, storeDiffers: [String])) -> String", in: code)
        XCTAssertEqual(try matches(#"^\{ ?"" ?\+ ?NewObjectSave\.undoSuffix\( ?restored\.storeDiffers ?\) ?\}$"#, in: message).count, 1, message)
        XCTAssertEqual(try matches(#"case \.deleteReminder\( ?let snapshot ?\) ?: ?return Self\.restoredReminderMessage\( ?try await restoreDeletedReminder\( ?snapshot ?\) ?\)"#, in: code).count, 1)
        // PR #282 integrates the batch arm with #248's narrowing: each member runs through
        // `undoBatchMember`, which takes a reminder's names from `restoreDeletedReminder` as data,
        // and the batch text builds its note from them with `differingFieldsNote`
        // (`UndoRestoredDifference.sentences`); no member text is read
        // back (`UndoBatchWiringTests.testTheUndoBatchArmCarriesRestoredRemindersDifferencesAsData`).
        let member = try body(of: "func undoBatchMember(_ operation: UndoOperation)", in: code)
        XCTAssertEqual(try matches(#"guard case \.deleteReminder\( ?let snapshot ?\) = operation else \{ ?return UndoMemberOutcome\( ?text: ?try await executeUndo\( ?operation ?\) ?, ?differing: ?\[ ?\] ?\) ?\} ?let restored = try await restoreDeletedReminder\( ?snapshot ?\) ?return UndoMemberOutcome\( ?text: ?Self\.restoredReminderMessage\( ?restored ?\) ?, ?differing: ?\[ ?UndoRestoredDifference\( ?title: ?restored\.title ?, ?storeDiffers: ?restored\.storeDiffers ?\) ?\] ?\)"#, in: member).count, 1,
                       "a batch undo collects each restored member's names and builds its note from them")
        XCTAssertEqual(try matches(#"restore: ?\{ ?try await self\.undoBatchMember\( ?\$0 ?\) ?\}"#, in: code).count, 1)
        XCTAssertEqual(try matches(#"UndoRestoredDifference\.sentences\( ?differing ?\)"#, in: code).count, 1)
        for handler in ["func handleCreateReminder(", "func handleCreateRemindersBatch(", "func handleCreateCalendar("] {
            let body = try body(of: handler, in: code)
            XCTAssertEqual(try matches(#"NewObjectSave\.responseFields\( ?result\.storeDiffers ?\)"#, in: body).count, 1, handler)
        }
        for site in [create, undoArm] {
            XCTAssertEqual(try matches(#"\bcatch\b|try[?!] ?saveNewReminder"#, in: site).count, 0, site)
        }
        // One formatter writes the note's wording; everything else calls it. Its wording appears
        // once in Sources (comments dropped, strings kept), so no code can look for it in text.
        let notes = try body(of: "static func responseFields(", in: code) + (try body(of: "static func undoSuffix(", in: code))
            + (try body(of: "static func sentences(_ differences: [UndoRestoredDifference])", in: code))
        XCTAssertEqual(try matches(#"differingFieldsNote\("#, in: notes).count, 3, notes)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheICalMCP")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let withStrings = try files.map { ReminderUndoWiringTests.strippingComments(try String(contentsOf: $0, encoding: .utf8)) }.joined(separator: "\n")
        XCTAssertEqual(withStrings.components(separatedBy: "the store holds a different").count - 1, 1, "the note's wording is written once, by differingFieldsNote")
        XCTAssertFalse(code.contains("batchSuffix"))
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
            XCTAssertEqual(try matches(#"var storeDiffers: ?\[String\] ?= ?\[ ?\] ?if NewObjectSave\.keepsFailedInsert\( ?\#(type) ?\) ?\{ ?storeDiffers = try NewObjectSave\.run\( ?save: ?\{ ?try \w+\.saveCalendar\( ?\#(name) ?, ?commit: ?true ?\) ?\} ?, ?"#
                                       + freshCheck("listCheck", name)
                                       + #" ?, ?discard: ?\{ ?try \w+\.removeCalendar\( ?\#(name) ?, ?commit: ?false ?\) ?\} ?, ?"#
                                       + report(#""""#, #"\#(name)\.calendarIdentifier"#)
                                       + #" ?\) ?\} ?else ?\{ ?try \w+\.saveCalendar\( ?\#(name) ?, ?commit: ?true ?\) ?\} ?markNeedsRefresh\( ?\) ?return CreateCalendarResult\( ?calendar: ?\#(name) ?, ?isDuplicate: ?false ?, ?storeDiffers: ?storeDiffers ?\) ?\}"#,
                                       in: body).count, 1, body)
        }
        // A list a new store finds after its save threw is created: nothing is caught on the way
        // to the result.
        let create = try body(of: "func createCalendar(", in: code)
        XCTAssertEqual(try matches(#"\bcatch\b|try[?!] ?NewObjectSave"#, in: create).count, 0, create)
    }

    /// The gate depends on one fact: the check reads a store made after the failure, never the
    /// one that saved (which finds its own pending insert, 6 of 6 on device). So the body of
    /// `freshStoreFinds` is pinned whole: one new `EKEventStore()`, released with its pool, nil
    /// when it has no sources, and the closure given that store and no other. It is the only
    /// `EKEventStore()` in its file, and the two save sites are its only callers. The closures
    /// they hand it (`reminderCheck`, `listCheck`) are pinned too: what they look up in that
    /// store, by which identifier, and that they compare it with the object as it was saved.
    func testTheCheckReadsANewStoreOnlyAndComparesItsCopy() throws {
        let code = try code()
        XCTAssertEqual(try matches(#"func freshStoreFinds\( ?_ check: ?\( ?EKEventStore ?\) ?-> ?Found ?\) ?-> ?Found\? ?\{"#, in: code).count, 1)
        let finds = try body(of: "func freshStoreFinds(", in: code)
        XCTAssertEqual(try matches(#"^\{ ?autoreleasepool ?\{ ?let store = EKEventStore\( ?\) ?return store\.sources\.isEmpty \? nil : check\( ?store ?\) ?\} ?\}$"#,
                                   in: finds).count, 1, finds)
        // What each site's check looks up in that store, and what it compares the object with.
        let reminderCheck = try body(of: "func reminderCheck(_ reminder: EKReminder) -> (EKEventStore) -> Found", in: code)
        XCTAssertEqual(try matches(#"^\{ ?\{ ?check\( ?Fields\( ?reminder: ?reminder ?\) ?, ?against: ?\( ?\$0\.calendarItem\( ?withIdentifier: ?reminder\.calendarItemIdentifier ?\) ?as\? ?EKReminder ?\)\.map\( ?Fields\.init\( ?reminder:\) ?\) ?\) ?\} ?\}$"#,
                                   in: reminderCheck).count, 1, reminderCheck)
        let listFields = try body(of: "init(list: EKCalendar)", in: code)
        XCTAssertEqual(try matches(#"list\.title ?, ?"" ?: ?list\.source\?\.sourceIdentifier ?\?\? ?"" ?\]"#, in: listFields).count, 1, listFields)
        let reminderFields = try body(of: "init(reminder: EKReminder)", in: code)
        XCTAssertEqual(try matches(#"reminder\.calendar\?\.calendarIdentifier ?\?\? ?"""#, in: reminderFields).count, 1, reminderFields)
        let listCheck = try body(of: "func listCheck(_ list: EKCalendar) -> (EKEventStore) -> Found", in: code)
        XCTAssertEqual(try matches(#"^\{ ?\{ ?check\( ?Fields\( ?list: ?list ?\) ?, ?against: ?\$0\.calendar\( ?withIdentifier: ?list\.calendarIdentifier ?\)\.map\( ?Fields\.init\( ?list:\) ?\) ?\) ?\} ?\}$"#,
                                   in: listCheck).count, 1, listCheck)
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheICalMCP/EventKit/NewObjectSave.swift")
        XCTAssertEqual(try matches(#"EKEventStore ?(?:\.init ?)?\("#, in: stripped(try String(contentsOf: file, encoding: .utf8))).count, 1)
        XCTAssertEqual(try matches(#"freshStoreFinds"#, in: code).count, 3, "the definition and the two save sites")
    }

    /// Every outcome reaches stderr as one escaped line: `logNewObjectOutcome` is pinned whole, so
    /// a report closure that swallows outcomes, or a log that drops one, fails here.
    func testEveryOutcomeIsWrittenAsOneEscapedLine() throws {
        let code = try code()
        XCTAssertEqual(try matches(#"func logNewObjectOutcome\( ?handler: ?String ?, ?identifier: ?String ?, ?_ outcome: ?NewObjectSave\.Outcome ?\) ?\{"#, in: code).count, 1)
        let body = try body(of: "func logNewObjectOutcome(", in: code)
        XCTAssertEqual(try matches(#"^\{ ?let note = NewObjectSave\.note\( ?for: ?outcome ?, ?handler: ?handler ?, ?identifier: ?identifier ?\) ?FileHandle\.standardError\.write\( ?Data\( ?\( ?EventKitErrorSanitizer\.escapeForStderr\( ?note ?\) ?\+ ?"" ?\)\.utf8 ?\) ?\) ?\}$"#,
                                   in: body).count, 1, body)
    }

    /// The stripper reads an interpolation that holds a quote (`"\(a ?? "x")"`, or one inside a
    /// call, `"\(list.joined(separator: ", "))"`) wrongly: the quote inside ends the string
    /// early, so the rest of the line can read as code, or code as string. It does not cross the
    /// line's end. So no such line may hold anything the pins above read. The pattern looks one
    /// level of parentheses deep into the interpolation; a deeper nesting before the quote is not
    /// found.
    func testNoPinnedCodeSharesALineWithAnInterpolatedQuote() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/CheICalMCP")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let pinned = ["commit:", "saveNewReminder", "EKReminder", "EKCalendar(", "NewObjectSave", "freshStoreFinds", "logNewObjectOutcome", "reset("]
        var seen = 0
        for file in files {
            for line in try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            where line.range(of: #"\\\((?:[^")]|\([^)]*\))*""#, options: .regularExpression) != nil {
                seen += 1
                XCTAssertFalse(pinned.contains { line.contains($0) }, "\(file.lastPathComponent): \(line)")
            }
        }
        XCTAssertGreaterThan(seen, 0, "the pattern finds the lines it guards")
        for nested in [#""\(list.joined(separator: ", "))""#, #""\(a ?? "x")""#, #""\(f(x) ?? "y")""#] {
            XCTAssertNotNil(nested.range(of: #"\\\((?:[^")]|\([^)]*\))*""#, options: .regularExpression), nested)
        }
        // The stated limit: two levels of parentheses before the quote are not found.
        XCTAssertNil(#""\(f(g(x)) ?? "y")""#.range(of: #"\\\((?:[^")]|\([^)]*\))*""#, options: .regularExpression))
        XCTAssertNil(#""\(handler)(\(identifier))""#.range(of: #"\\\((?:[^")]|\([^)]*\))*""#, options: .regularExpression))
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
