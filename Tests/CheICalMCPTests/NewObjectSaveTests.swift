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
        if case .discardFailed = outcome { return "discardFailed" }
        return "\(outcome)"
    }

    /// Same domain and code (a Swift error is compared through its NSError bridge).
    private func code(_ error: Error?) -> String? {
        error.map { "\(($0 as NSError).domain) \(($0 as NSError).code)" }
    }

    /// Runs the helper with closures that record each call; `report` records the outcome by name.
    private func run(save: @escaping () throws -> Void = { throw Failure.commit }, committed: Bool?,
                     discard: @escaping () throws -> Void = {}) -> (calls: [String], error: Error?) {
        var calls: [String] = []
        do {
            try NewObjectSave.run(save: { calls.append("save"); try save() },
                                  committed: { calls.append("committed"); return committed },
                                  discard: { calls.append("discard"); try discard() },
                                  report: { calls.append("report \(self.name($0))") })
            return (calls, nil)
        } catch {
            return (calls, error)
        }
    }

    func testASuccessfulSaveRunsNothingElse() {
        let result = run(save: {}, committed: false)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.calls, ["save"])
    }

    /// The default: a failed save that a new store cannot find is discarded once, after the
    /// check and before the error reaches the caller. Nothing is logged.
    func testAFailedSaveANewStoreCannotFindIsDiscardedOnceBeforeItsErrorLeaves() {
        let result = run(committed: false)
        XCTAssertEqual(result.error as? Failure, .commit)
        XCTAssertEqual(result.calls, ["save", "committed", "discard"])
    }

    /// A new store finds the object: the save committed and then threw. The object is kept and
    /// `run` returns, so every caller takes its success path (the create's result and undo
    /// record, the refresh mark; delete-undo consumes its record). Reported once, nothing removed.
    func testAFailedSaveANewStoreFindsIsKeptAndTheCallSucceeds() {
        let result = run(committed: true)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.calls, ["save", "committed", "report committedThenThrew"])
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
        for committed in [false, nil] as [Bool?] {
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
            XCTAssertThrowsError(try NewObjectSave.run(save: { throw saveError }, committed: { false },
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
            XCTAssertThrowsError(try NewObjectSave.run(save: { throw saveError }, committed: { false },
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
        XCTAssertEqual(NewObjectSave.note(for: .committedThenThrew, handler: "h", identifier: "id"),
                       "h(id): the save threw, but a new store finds the item, so it was saved; it is kept and the call succeeds")
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

    /// The code from `start` to the next method or switch case. A `case .` inside a creating
    /// method (e.g. `if case .x`) would cut the segment short and fail the pin, not pass it.
    private func segment(of text: String, at start: String.Index) -> String {
        let rest = text[text.index(after: start)...]
        let ends = [" func ", " case ."].compactMap { rest.range(of: $0)?.lowerBound }
        return String(text[start..<(ends.min() ?? text.endIndex)])
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

    /// The `committed` check the save sites pass: a store made after the failure finds the object.
    private func freshCheck(_ lookup: String, _ id: String) -> String {
        #"committed: ?\{ ?NewObjectSave\.freshStoreFinds ?\{ ?\$0\.\#(lookup)\( ?withIdentifier: ?\#(id) ?\) ?!= ?nil ?\} ?\}"#
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
                                   + freshCheck("calendarItem", #"reminder\.calendarItemIdentifier"#)
                                   + #" ?, ?discard: ?\{ ?try \w+\.remove\( ?reminder ?, ?commit: ?false ?\) ?\} ?, ?"#
                                   + report(#"handler"#, #"reminder\.calendarItemIdentifier"#) + #" ?\) ?\}$"#,
                                   in: try body(of: "func saveNewReminder(", in: code)).count, 1, wrapper)
        // When `saveNewReminder` returns, after a save or after a save that threw but that a new
        // store finds, each caller goes on to its success path, with nothing caught in between:
        // create_reminder marks the store for a refresh, builds the result and records the undo
        // entry; delete-undo marks the refresh and reports the restore (its record is consumed).
        let create = try body(of: "func createReminder( title:", in: code)
        XCTAssertEqual(try matches(#"try saveNewReminder\( ?reminder ?, ?handler: ?"" ?\) ?markNeedsRefresh\( ?\) ?let result = CreateReminderResult\( ?reminder: ?ReminderWriteSnapshot\( ?from: ?reminder ?\) ?, ?isDuplicate: ?false ?\) ?let createdID = result\.reminder\.calendarItemIdentifier ?await CalendarUndoManager\.shared\.record\( ?\.createReminder\( ?id: ?createdID ?,"#,
                                   in: create).count, 1, create)
        let undoArm = try segment(of: code, from: "applyReminderSnapshot(snapshot, for: .recreateDeleted")
        XCTAssertEqual(try matches(#"try saveNewReminder\( ?reminder ?, ?handler: ?"" ?\) ?markNeedsRefresh\( ?\) ?return "" ?$"#, in: undoArm).count, 1, undoArm)
        for site in [create, undoArm] {
            XCTAssertEqual(try matches(#"\bcatch\b|try[?!] ?saveNewReminder"#, in: site).count, 0, site)
        }
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
                                       + #" ?, ?discard: ?\{ ?try \w+\.removeCalendar\( ?\#(name) ?, ?commit: ?false ?\) ?\} ?, ?"#
                                       + report(#""""#, #"\#(name)\.calendarIdentifier"#)
                                       + #" ?\) ?\} ?else ?\{ ?try \w+\.saveCalendar\( ?\#(name) ?, ?commit: ?true ?\) ?\} ?markNeedsRefresh\( ?\) ?return CreateCalendarResult\( ?calendar: ?\#(name) ?, ?isDuplicate: ?false ?\) ?\}"#,
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
    /// when it has no sources, and the closure given that store and nothing else. It is the only
    /// `EKEventStore()` in its file, and the two save sites are its only callers.
    func testTheCheckReadsANewStoreAndNothingElse() throws {
        let code = try code()
        XCTAssertEqual(try matches(#"func freshStoreFinds\( ?_ find: ?\( ?EKEventStore ?\) ?-> ?Bool ?\) ?-> ?Bool\? ?\{"#, in: code).count, 1)
        let body = try body(of: "func freshStoreFinds(", in: code)
        XCTAssertEqual(try matches(#"^\{ ?autoreleasepool ?\{ ?let store = EKEventStore\( ?\) ?return store\.sources\.isEmpty \? nil : find\( ?store ?\) ?\} ?\}$"#,
                                   in: body).count, 1, body)
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
        for nested in [#""\(list.joined(separator: ", "))""#, #""\(a ?? "x")""#] {
            XCTAssertNotNil(nested.range(of: #"\\\((?:[^")]|\([^)]*\))*""#, options: .regularExpression), nested)
        }
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
