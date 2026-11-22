import XCTest
@testable import CheICalMCP

/// #532, #534, #535: the call sites in `EventKitManager`, which work on the event store, where no
/// seam reaches. What each site decides is tested in `EditedOccurrenceAddressTests`; these pins
/// hold that the sites ask it, in the branch where the lookup missed, before anything is written.
final class EditedOccurrenceAddressWiringTests: XCTestCase {
    private func manager() throws -> String { try SourcePins.source("EventKit/EventKitManager.swift") }

    /// One function's code, comments and string literals blanked, whitespace collapsed.
    private func body(of declaration: String) throws -> String {
        SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: declaration, in: try manager()), declaration))
    }

    private func repoFile(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    /// `needle` occurs exactly once in `text` (a pin that only asks whether it occurs survives a
    /// second, different call next to it).
    private func assertOnce(_ needle: String, in text: String, _ what: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(count(needle, in: text), 1, "\(what) \(needle)", file: file, line: line)
    }

    /// Every spelling a write, a history record or a log line has in the two files the search lives in.
    /// Each is spelled somewhere in Sources (checked below), so none of them guards nothing. A store
    /// commit or reset is covered by `.commit(` and by no entry: `reset(` is not called on a store in
    /// Sources, and neither `NSLog(` nor `fputs(` is used there.
    private let writes = ["eventStore.save(", "eventStore.remove(", "eventStore.saveCalendar(", "eventStore.removeCalendar(",
                          ".save(", ".remove(", ".commit(", "CalendarUndoManager", ".record(", "saveNewReminder(",
                          "saveExistingReminder(", "saveExistingCalendar(", "saveForHistory(", "saveUnchecked(", "saveCopy(", "removeMoveCopy(",
                          "removeExistingReminder(", "removeExistingCalendar(", "commitReminderRemoval(", "recordUnreadUpdate(", "removeAlarm(",
                          ".calendar = ", ".title = ", ".startDate = ", ".endDate = ", "FileHandle.standardError", "print(",
                          "writeFailureLog("]


    /// The three write tools: the lookup's miss branch is the one place the search is asked, it
    /// throws what the search answers, and nothing is saved, removed or assigned before it.
    // spec-example: edited-occurrence-addressing / A plain occurrence still resolves
    func testTheMissBranchOfEachWriteAsksTheSearchBeforeAnythingIsWritten() throws {
        let sites: [(declaration: String, series: String, call: String)] = [
            ("func updateEvent(", "masterEvent", ".update(futureSpan: span == .futureEvents)"),
            ("func deleteEvent(", "masterEvent", ".delete(futureSpan: span == .futureEvents)"),
            ("func moveEvent(", "master", ".moveRow"),
        ]
        for site in sites {
            let code = try body(of: site.declaration)
            XCTAssertEqual(count("findOccurrence(", in: code), 1, site.declaration)
            XCTAssertEqual(count("occurrenceMissError(", in: code), 1, site.declaration)
            // The lookup keeps its form (`OccurrenceDateZoneTests` pins the zone it searches in).
            let lookup = "guard let occurrence = findOccurrence(identifier: identifier, on: date, in: Self.occurrenceZone(of: \(site.series))) else {"
            let miss = "\(lookup) throw occurrenceMissError(series: \(site.series), id: identifier, on: date, call: \(site.call)) }"
            let at = try XCTUnwrap(code.range(of: miss), "\(site.declaration): \(miss)")
            let before = String(code[..<at.lowerBound])
            for write in ["eventStore.save(", "eventStore.remove(", ".calendar = ", "event.title = ", "event.startDate = "] {
                XCTAssertFalse(before.contains(write), "\(site.declaration): \(write) before the lookup")
            }
            // The occurrence the lookup resolved is used as before.
            XCTAssertTrue(String(code[at.upperBound...]).contains("occurrence"), site.declaration)
        }
    }

    /// The search runs first, its matches decide the answer, and neither it nor what it calls writes.
    func testTheMissErrorIsBuiltFromTheSearchAndWritesNothing() throws {
        let miss = try body(of: "func occurrenceMissError(")
        // What was asked is built once, from the object the lookup searched with, and the zone goes
        // in as it is: a default in its place would read the day of a series with no time zone in
        // another zone than the lookup's and hide its #549 text (PR #545 verify).
        let asked = "let request = EditedOccurrenceAddress.Request(seriesID: id, seriesIsAllDay: series.isAllDay, seriesZone: Self.occurrenceZone(of: series), requested: date)"
        let decide = "switch EditedOccurrenceAddress.miss(for: call, matches: editedOccurrences(for: request), request: request) {"
        assertOnce(asked, in: miss)
        assertOnce(decide, in: miss)
        let notFound = ".eventNotFound(identifier: detail)"
        assertOnce(notFound, in: miss)
        XCTAssertLessThan(try XCTUnwrap(miss.range(of: asked)).lowerBound, try XCTUnwrap(miss.range(of: decide)).lowerBound)
        XCTAssertLessThan(try XCTUnwrap(miss.range(of: decide)).lowerBound, try XCTUnwrap(miss.range(of: notFound)).lowerBound)
        assertOnce("case .refusal(let reason): return call == .moveRow ? .moveRefused(reason: reason) : .occurrenceAddressRefused(reason: reason)", in: miss)
        assertOnce("case .notFound(let detail): return call == .moveRow ? .moveRefused(reason: Self.noOccurrenceOnDateReason) : .eventNotFound(identifier: detail)", in: miss)
        assertOnce("EditedOccurrenceAddress.Request(", in: miss)
        assertOnce("editedOccurrences(", in: miss)

        // Only the day's events are read, in the series' zone as it is; the series is not listed
        // (PR #545 narrowing round).
        let edited = try body(of: "func editedOccurrences(")
        assertOnce("func editedOccurrences(for request: EditedOccurrenceAddress.Request) -> [EditedOccurrenceAddress.Match] { EditedOccurrenceAddress.matches(onDay: dayReadings(containing: request.requested, in: request.seriesZone), for: request) }", in: edited)
        assertOnce("dayReadings(", in: edited)
        assertOnce("EditedOccurrenceAddress.matches(", in: edited)
        for listing in ["seriesOccurrences(", "seriesReadings(", "listingRange", "predicateForEvents(", "enumerateEvents("] {
            XCTAssertFalse(edited.contains(listing), "editedOccurrences lists: \(listing)")
            XCTAssertFalse(miss.contains(listing), "occurrenceMissError lists: \(listing)")
        }

        // The day's events: the window and the predicate of the lookup (`OccurrenceDayTests` pins the
        // same two statements in `findOccurrence`), opening the body, with neither input rebound.
        let day = try body(of: "func dayReadings(")
        let window = "guard let window = OccurrenceDay.candidateWindow(containing: date, in: timeZone) else { return [] } let predicate = eventStore.predicateForEvents(withStart: window.start, end: window.end, calendars: nil)"
        assertOnce(window, in: day)
        let opens = try XCTUnwrap(day.range(of: "func dayReadings(containing date: Date, in timeZone: TimeZone?) -> [EditedOccurrenceAddress.Reading] { "), day)
        XCTAssertTrue(day[opens.upperBound...].hasPrefix(window), String(day.prefix(300)))
        assertOnce("predicateForEvents(", in: day)
        assertOnce("eventStore.enumerateEvents(matching: predicate)", in: day)
        for rebinding in ["let date", "var date", "let timeZone", "var timeZone", "date =", "timeZone ="] {
            XCTAssertFalse(day.contains(rebinding), "dayReadings rebinds an input: \(rebinding)")
        }

        // No default zone at any of the sites that hand a zone to the search.
        for code in [miss, edited, day] {
            XCTAssertFalse(code.contains("?? .current"), code)
            XCTAssertFalse(code.contains("TimeZone.current"), code)
        }

        // Nothing the search runs writes, records history or logs: its three functions.
        for (name, code) in [("occurrenceMissError", miss), ("editedOccurrences", edited), ("dayReadings", day)] {
            for write in writes {
                XCTAssertFalse(code.contains(write), "\(name): \(write)")
            }
        }
        // The deny-list is live: every entry of it is spelled somewhere in Sources (comments
        // stripped), so an entry that matches nothing shows here (PR #545 verify round 2: four did).
        let sources = try SourceScan.swiftFiles().map { SourceScan.strippingComments(try String(contentsOf: $0, encoding: .utf8)) }.joined(separator: "\n")
        for spelled in writes {
            XCTAssertTrue(sources.contains(spelled), "matches nothing in Sources: \(spelled)")
        }
    }

    /// #555 item 8: each reading of the day is built from the event alone, through
    /// `EditedOccurrenceAddress.Reading(_:)`, and nothing else is read in the loop; the initializer
    /// itself reads the identifier, all-day state, start and zone only (PR #562 verify r1, K8). The pins above hold the
    /// window, the predicate and the enumeration; without this one a slot read added inside the loop
    /// (`occurrenceDate`, the external identifier, `isDetached`) would pass them all.
    func testEachReadingOfTheDayIsBuiltFromTheEventAlone() throws {
        let day = try body(of: "func dayReadings(")
        let whole = "func dayReadings(containing date: Date, in timeZone: TimeZone?) -> [EditedOccurrenceAddress.Reading] { guard let window = OccurrenceDay.candidateWindow(containing: date, in: timeZone) else { return [] } let predicate = eventStore.predicateForEvents(withStart: window.start, end: window.end, calendars: nil) var readings: [EditedOccurrenceAddress.Reading] = [] eventStore.enumerateEvents(matching: predicate) { event, _ in readings.append(EditedOccurrenceAddress.Reading(event)) } return readings }"
        XCTAssertEqual(day, whole)
        for slot in ["occurrenceDate", "calendarItemExternalIdentifier", "isDetached", "/RID="] {
            XCTAssertFalse(day.contains(slot), "dayReadings reads \(slot)")
        }
        // PR #562 verify r1 (K8): the initializer the loop calls reads the four fields and nothing
        // else, the start from `startDate`, not a slot. The body is pinned exactly, where the
        // deny-lists above and in `testTheSearchReadsNoSlotAndListsNoSeries` name only spellings
        // (which already turn red on `occurrenceDate` in its place, PR #562 verify r2).
        let reading = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "init(_ event: EKEvent)",
                                                                                   in: try SourcePins.source("EventKit/EditedOccurrenceAddress.swift"))))
        XCTAssertEqual(reading, "init(_ event: EKEvent) { self.init(eventIdentifier: event.eventIdentifier, isAllDay: event.isAllDay, start: event.startDate, timeZone: event.timeZone) }")
    }

    /// The lookup itself is as it was: by the exact identifier, for an occurrence starting on the day.
    func testTheLookupStillTestsTheExactIdentifier() throws {
        let find = try body(of: "func findOccurrence(")
        assertOnce("FutureDeletionCoverage.isRequested(eventIdentifier: event.eventIdentifier, occurrenceDate: event.occurrenceDate, identifier: identifier, slot: slot)", in: find)
        assertOnce("OccurrenceDay.startsOnRequestedDay(occurrenceStart: event.startDate, isAllDay: event.isAllDay, requested: date, in: timeZone)", in: find)
        assertOnce("FutureDeletionCoverage.isRequested(", in: find)
        assertOnce("OccurrenceDay.startsOnRequestedDay(", in: find)
        XCTAssertFalse(find.contains("EditedOccurrenceAddress"), find)
        // The two callers this change leaves alone still call it directly.
        XCTAssertFalse(try body(of: "func deleteEventsBatch(").contains("occurrenceMissError("))
        XCTAssertFalse(try body(of: "func applyExclusions(").contains("EditedOccurrenceAddress"))
    }

    /// #534: the exclusion check of `createEvent` asks what the date still holds, with the lookup's
    /// answer and the day's events, and throws the conflict of the case: the lookup's as before, and
    /// one of its own for an occurrence edited on its own.
    func testTheExclusionCheckCountsAnEditedOccurrenceOnTheDay() throws {
        let create = try body(of: "func createEvent(")
        let check = "for date in excluded { switch EditedOccurrenceAddress.presence( lookupHit: findOccurrence(identifier: existingId, on: date, in: tz) != nil, onDay: dayReadings(containing: date, in: tz), seriesID: existingId, requested: date, zone: tz) { case .absent: continue case .resolved: throw EventKitError.exclusionConflict( existingId: existingId, date: Self.formatExclusionDay(date, timezone: tz)) case .editedOccurrenceStarts: throw EventKitError.exclusionEditedOccurrence( existingId: existingId, date: Self.formatExclusionDay(date, timezone: tz)) } }"
        assertOnce(check, in: create)
        assertOnce("findOccurrence(", in: create)
        assertOnce("EditedOccurrenceAddress.presence(", in: create)
        assertOnce("EventKitError.exclusionEditedOccurrence(", in: create)
        // Only the day is read: the series is not listed in the create path, and no slot is read.
        XCTAssertFalse(create.contains("seriesReadings("), create)
        XCTAssertFalse(create.contains("editedOccurrences("), create)
        XCTAssertFalse(create.contains("EditedOccurrenceAddress.matches("), create)
        let address = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "static func presence(", in: try SourcePins.source("EventKit/EditedOccurrenceAddress.swift"))))
        for slot in ["ruleSlot", "originalSlot", "occurrenceDate", "matches("] {
            XCTAssertFalse(address.contains(slot), "presence reads a slot: \(slot)")
        }
        assertOnce("DetachedOccurrenceSpan.seriesIdentifier(of: identifier) == seriesID", in: address)
    }

    /// #535: the not-found text is built by the formatter; the date's own description is not
    /// interpolated into it any more.
    func testTheNotFoundTextNoLongerInterpolatesTheDate() throws {
        let source = SourceScan.strippingComments(try manager())
        XCTAssertFalse(source.contains("(no occurrence on \\(date))"), "the UTC description of the date")
        XCTAssertEqual(count("no occurrence on", in: source), 0)
        let address = SourceScan.strippingComments(try SourcePins.source("EventKit/EditedOccurrenceAddress.swift"))
        XCTAssertEqual(count("(no occurrence on \\(request.day))", in: address), 1)
    }

    /// The span `future` route, its ending and its limits are written once each, in
    /// `DetachedOccurrenceSpan`, and read from there by both refusals; a copy in the new text could
    /// drift from the #416 text.
    func testTheSpanFutureRouteIsWrittenOnce() throws {
        let address = SourceScan.strippingComments(try SourcePins.source("EventKit/EditedOccurrenceAddress.swift"))
        let span = SourceScan.strippingComments(try SourcePins.source("EventKit/DetachedOccurrenceSpan.swift"))
        for phrase in ["for the later ones the id list_events shows", "this shape has no tested way yet", "If that id is refused,",
                       "That way leaves out all_day, clear_recurrence and calendar_name"] {
            var total = 0
            for file in try SourceScan.swiftFiles() {
                total += count(phrase, in: SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
            }
            XCTAssertEqual(total, 1, phrase)
            assertOnce(phrase, in: span)
        }
        for constant in ["DetachedOccurrenceSpan.laterOccurrencesRoute", "DetachedOccurrenceSpan.ifThatIdIsRefused", "DetachedOccurrenceSpan.laterOccurrencesLimits"] {
            assertOnce(constant, in: address)
        }
        // What is read of an event carries its own time zone (the move row prints its day there).
        assertOnce("start: event.startDate, timeZone: event.timeZone)", in: SourceScan.collapsingWhitespace(address))
        // The new type writes nothing anywhere: no log line can carry an identifier.
        for write in ["FileHandle.standardError", "fputs(", "print(", "writeFailureLog(", "NSLog("] {
            XCTAssertFalse(address.contains(write), write)
        }
    }

    /// PR #545 narrowing round: the search reads no slot. What is read of an event is its
    /// identifier, all-day state, start and zone, and nothing in the search's file reads the digits
    /// after `/RID=` as a number or a date, or reads an occurrence date, an external identifier or
    /// `isDetached`. The only code that looks past the marker is the shape check of the echo, which
    /// tests that the digits are ASCII digits. The series listing of the earlier rounds is gone.
    // spec-example: edited-occurrence-addressing / The search reads no slot
    func testTheSearchReadsNoSlotAndListsNoSeries() throws {
        let address = SourceScan.strippingComments(try SourcePins.source("EventKit/EditedOccurrenceAddress.swift"))
        for reads in ["ruleSlot", "originalSlot", "occurrenceDate", "externalIdentifier", "calendarItemExternalIdentifier", "isDetached",
                      "timeIntervalSinceReferenceDate", "Date(timeInterval", "Int(", "Double(", "TimeInterval(", "originalDay", "listingRange",
                      "seriesStart", "readsSlots", "slotOffSeriesTime", "originallyThatDay", "addressesOneOccurrence"] {
            XCTAssertFalse(address.contains(reads), "the search's file reads a slot or lists a series: \(reads)")
        }
        let collapsed = SourceScan.collapsingWhitespace(address)
        assertOnce("self.init(eventIdentifier: event.eventIdentifier, isAllDay: event.isAllDay, start: event.startDate, timeZone: event.timeZone)", in: collapsed)
        // The marker is used twice: by the series part of an identifier (`seriesIdentifier`, which
        // reads what is before it) and by the echo's shape check (digits are digits).
        assertOnce("DetachedOccurrenceSpan.slotMarker", in: address)
        assertOnce("let digits = identifier.unicodeScalars.dropFirst(prefix.unicodeScalars.count)", in: collapsed)
        assertOnce("guard !digits.isEmpty, digits.allSatisfy({ (\"0\"...\"9\").contains($0) }) else { return nil }", in: collapsed)
        XCTAssertEqual(count("digits", in: address), 3, "digits are used only by the echo's shape check")
        // No listing of the series is left for this search in Sources.
        for file in try SourceScan.swiftFiles() {
            let code = SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8))
            XCTAssertFalse(code.contains("seriesReadings("), file.lastPathComponent)
            XCTAssertFalse(code.contains("EditedOccurrenceAddress.listingRange"), file.lastPathComponent)
        }
    }

    // MARK: - Documents

    /// Each phrase once in its document (a phrase that could occur twice survives the removal of the
    /// passage it is meant to hold).
    func testTheDocumentsDescribeTheRefusalOnce() throws {
        let pins: [(file: String, phrases: [String])] = [
            ("README.md", ["so the series' identifier and that day do not address it",
                           "an occurrence edited on its own that starts on an excluded date is a conflict",
                           "(no occurrence on 2026-12-21)",
                           "An occurrence that was not edited on its own and starts on the day is resolved and written to as before.",
                           "That entry is read in the occurrence's own time zone",
                           "whose identifier has another shape",
                           "Google and Exchange were not run for this change",
                           "`No occurrence of this event falls on occurrence_date.`",
                           "answers `deleted`, and leaves the edited occurrence itself",
                           "(#548, cause not separated)",
                           // PR #545 narrowing round.
                           "an occurrence edited on its own and moved to another day, asked for by the day it was moved off",
                           "and this server does not read that date. So the refusal says both directions without the original date",
                           "Every span `future` refusal also says, whatever the occurrence, what #550 measured on iCloud",
                           "no refusal prints or implies the original date of an occurrence"]),
            ("README_zh-TW.md", ["所以系列識別碼加那一天指不到它",
                                 "在排除日開始、被單獨修改過的場次算衝突",
                                 "(no occurrence on 2026-12-21)",
                                 "沒被單獨修改過、在那一天開始的場次照舊找得到、照舊寫入。",
                                 "這一項是用場次自己的時區讀的",
                                 "ID 是別種形狀的被修改場次",
                                 "這次改動沒有在 Google 與 Exchange 上跑",
                                 "`No occurrence of this event falls on occurrence_date.`",
                                 "回應 `deleted`，卻留下被修改的那個場次本身",
                                 "（#548，原因還沒分開）",
                                 "被單獨修改過並移到別天的場次，用它被移走的那一天來指",
                                 "所以訊息不寫原本的日期，寫出兩個方向",
                                 "都會寫出 #550 在 iCloud 量到的",
                                 "任何拒絕訊息都不寫、也不暗示場次原本的日期"]),
            ("CHANGELOG.md", ["A series' identifier and a day no longer answer not found for an occurrence edited on its own",
                              "an excluded date that still holds an occurrence edited on its own is a conflict",
                              "The not-found answer of `update_event` and `delete_event` prints the requested day, not a UTC instant",
                              "answer a conflict error of its own",
                              "Google and Exchange were not run for this change",
                              "the call answers `deleted`, and the edited occurrence itself stays, #549",
                              "an occurrence edited on its own and moved to another day, asked for by the day it was moved off",
                              "give both directions without the original date",
                              "No refusal prints or implies an occurrence's original date."]),
            (".claude/rules/mcp-binary-version-testing.md", ["## Release gate：系列識別碼加日期指到被單獨修改過的場次（#532、#534、#535）",
                                                             "這個呼叫會被 #532 的訊息拒絕",
                                                             "4. **T（被移到別天的場次）**",
                                                             "8. **F（沒有時區的系列，PR #545 verify r1）**",
                                                             "9. **L（開始很久的系列，PR #545 verify r1）**",
                                                             "10. **R3（被往後移的場次與 span `future`，PR #545 verify r1）**",
                                                             "11. **Z（有自己時區的場次，PR #545 verify r1）**",
                                                             "12. **常駐 process（session MCP；這一格沒有做過，出版前要做）**",
                                                             "13. **G（場次被修改之後才有時區的系列，PR #545 verify r2）**",
                                                             "session MCP 只用在第 12 格",
                                                             "**至少一小時後再查",
                                                             "任何一則拒絕訊息都不可以有原本的日期"]),
        ]
        for pin in pins {
            let text = try repoFile(pin.file)
            for phrase in pin.phrases {
                XCTAssertEqual(count(phrase, in: text), 1, "\(pin.file): \(phrase)")
            }
        }
    }
}
