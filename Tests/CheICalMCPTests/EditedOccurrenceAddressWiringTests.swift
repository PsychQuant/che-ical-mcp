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
    private let writes = ["eventStore.save(", "eventStore.remove(", "eventStore.commit(", "eventStore.saveCalendar(", "eventStore.removeCalendar(",
                          "eventStore.reset(", ".save(", ".remove(", ".commit(", "CalendarUndoManager", ".record(", "saveNewReminder(",
                          "saveExistingReminder(", "saveExistingCalendar(", "saveForHistory(", "saveUnchecked(", "saveCopy(", "removeMoveCopy(",
                          "removeExistingReminder(", "removeExistingCalendar(", "commitReminderRemoval(", "recordUnreadUpdate(", "removeAlarm(",
                          ".calendar = ", ".title = ", ".startDate = ", ".endDate = ", "FileHandle.standardError", "fputs(", "print(", "NSLog(",
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
        // in as it is: a default in its place would hide a series with no time zone, whose slots are
        // not read (PR #545 verify).
        let asked = "let request = EditedOccurrenceAddress.Request(seriesID: id, seriesIsAllDay: series.isAllDay, seriesZone: Self.occurrenceZone(of: series), requested: date)"
        let decide = "switch EditedOccurrenceAddress.miss(for: call, matches: editedOccurrences(ofSeries: series, for: request), request: request) {"
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

        // The listing is made over the range around the requested day, once, and the day's events
        // are read in the series' zone as it is.
        let edited = try body(of: "func editedOccurrences(")
        assertOnce("let listed = EditedOccurrenceAddress.listingRange(for: request).flatMap { seriesReadings(of: series, id: request.seriesID, over: $0) }", in: edited)
        assertOnce("return EditedOccurrenceAddress.matches(onDay: dayReadings(containing: request.requested, in: request.seriesZone), listed: listed, for: request)", in: edited)
        assertOnce("seriesReadings(", in: edited)
        assertOnce("dayReadings(", in: edited)
        assertOnce("EditedOccurrenceAddress.matches(", in: edited)

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

        // Nothing the search runs writes, records history or logs: its three functions here, and
        // the two it calls in the listing file.
        let listing = try SourcePins.source("EventKit/FirstRemainingOccurrence.swift")
        func listingBody(_ declaration: String) throws -> String {
            SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: declaration, in: listing), declaration))
        }
        let readings = try listingBody("func seriesReadings(")
        let occurrences = try listingBody("private func seriesOccurrences(")
        for (name, code) in [("occurrenceMissError", miss), ("editedOccurrences", edited), ("dayReadings", day),
                             ("seriesReadings", readings), ("seriesOccurrences", occurrences)] {
            for write in writes {
                XCTAssertFalse(code.contains(write), "\(name): \(write)")
            }
        }
        // The deny-list is live: each store write, the history record and the log helper are spelled
        // somewhere in the manager, so a spelling that matched nothing would show here.
        let manager = SourceScan.strippingComments(try manager())
        for spelled in ["eventStore.save(", "eventStore.remove(", "CalendarUndoManager", ".record(", "saveForHistory(", "saveUnchecked("] {
            XCTAssertTrue(manager.contains(spelled), spelled)
        }
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
        // The new type writes nothing anywhere: no log line can carry an identifier.
        for write in ["FileHandle.standardError", "fputs(", "print(", "writeFailureLog(", "NSLog("] {
            XCTAssertFalse(address.contains(write), write)
        }
    }

    /// The listing the search reads is made over the range it is handed, through the function the
    /// other checks list a series with, and a listing kept for other ranges is not served for it.
    func testTheListingIsMadeOverTheRangeAroundTheRequestedDay() throws {
        let source = try SourcePins.source("EventKit/FirstRemainingOccurrence.swift")
        let readings = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func seriesReadings(", in: source)))
        assertOnce("seriesOccurrences(of: stale, id: id, ranges: [range])?.0.map(EditedOccurrenceAddress.Reading.init)", in: readings)
        assertOnce("seriesOccurrences(", in: readings)
        assertOnce("func seriesReadings(of stale: EKEvent, id: String, over range: DateInterval) -> [EditedOccurrenceAddress.Reading]?", in: SourceScan.strippingComments(source))
        // The ranges that are listed are the ones in the key of the kept listing.
        let occurrences = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "private func seriesOccurrences(", in: source)))
        assertOnce("ranges: ranges ?? SeriesExceptionsPlanner.listingRanges(for: window))", in: occurrences)
        assertOnce("for range in ranges ?? SeriesExceptionsPlanner.listingRanges(for: window) {", in: occurrences)
        assertOnce("let predicate = eventStore.predicateForEvents(withStart: range.start, end: range.end, calendars: [calendar])", in: occurrences)

        let day: TimeInterval = 86_400
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        func key(_ ranges: [DateInterval]) -> SeriesListingKey {
            SeriesListingKey(calendarIdentifier: "C", eventIdentifier: "S", externalIdentifier: "UID", ranges: ranges)
        }
        let around = key([DateInterval(start: start, duration: 733 * day)])
        let scan = key([DateInterval(start: start.addingTimeInterval(-2000 * day), duration: 1460 * day)])
        XCTAssertNotEqual(around, scan)
        let memo = SeriesListingMemo<String>()
        var made: [String] = []
        memo.sharing {
            for (name, key) in [("scan", scan), ("around", around), ("around", around)] {
                made.append(memo.listing(for: key) { name })
            }
        }
        XCTAssertEqual(made, ["scan", "around", "around"], "the listing kept for the scan ranges is not read for the range around the day")
    }

    // MARK: - Documents

    /// Each phrase once in its document (a phrase that could occur twice survives the removal of the
    /// passage it is meant to hold).
    func testTheDocumentsDescribeTheRefusalOnce() throws {
        let pins: [(file: String, phrases: [String])] = [
            ("README.md", ["the series' identifier and that day no longer address it",
                           "an occurrence edited on its own that starts on an excluded date is a conflict",
                           "(no occurrence on 2026-12-21)",
                           // PR #545 verify round 1: when the refusal applies, and the limits.
                           "An occurrence that was not edited on its own and starts on the day is resolved and written to as before.",
                           "more than a year (366 days) away from the day asked for",
                           "in a timed series with no time zone, an occurrence asked for by its original day",
                           "That entry is read in the occurrence's own time zone",
                           "whose identifier has another shape",
                           "Google and Exchange were not run for this change",
                           "`No occurrence of this event falls on occurrence_date.`"]),
            ("README_zh-TW.md", ["系列識別碼加那一天已經指不到它",
                                 "在排除日開始、被單獨修改過的場次算衝突",
                                 "(no occurrence on 2026-12-21)",
                                 "沒被單獨修改過、在那一天開始的場次照舊找得到、照舊寫入。",
                                 "超過一年（366 天）",
                                 "沒有時區的非全天系列裡",
                                 "這一項是用場次自己的時區讀的",
                                 "ID 是別種形狀的被修改場次",
                                 "這次改動沒有在 Google 與 Exchange 上跑",
                                 "`No occurrence of this event falls on occurrence_date.`"]),
            ("CHANGELOG.md", ["A series' identifier and a day no longer answer not found for an occurrence edited on its own",
                              "an excluded date that still holds an occurrence edited on its own is a conflict",
                              "The not-found answer of `update_event` and `delete_event` prints the requested day, not a UTC instant",
                              "the occurrence was moved more than 366 days away from the requested day",
                              "its `/RID=` is wall time read as UTC and is not read as a slot here",
                              "answer a conflict error of its own",
                              "Google and Exchange were not run for this change"]),
            (".claude/rules/mcp-binary-version-testing.md", ["## Release gate：系列識別碼加日期指到被單獨修改過的場次（#532、#534、#535）",
                                                             "這個呼叫會被 #532 的訊息拒絕",
                                                             "8. **F（沒有時區的系列，PR #545 verify r1）**",
                                                             "9. **L（開始很久的系列，PR #545 verify r1）**",
                                                             "10. **R3（被往後移的場次與 span `future`，PR #545 verify r1）**",
                                                             "11. **Z（有自己時區的場次，PR #545 verify r1）**",
                                                             "12. **常駐 process（session MCP；這一格沒有做過，出版前要做）**",
                                                             "那個代表場次被單獨改成另一種全天狀態"]),
        ]
        for pin in pins {
            let text = try repoFile(pin.file)
            for phrase in pin.phrases {
                XCTAssertEqual(count(phrase, in: text), 1, "\(pin.file): \(phrase)")
            }
        }
    }
}
