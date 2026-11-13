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
        // The day is read in the zone the lookup searched in.
        let zone = try XCTUnwrap(miss.range(of: "let timeZone = Self.occurrenceZone(of: series)"))
        let search = try XCTUnwrap(miss.range(of: "let matches = editedOccurrences(ofSeries: series, id: id, on: date, in: timeZone)"))
        XCTAssertLessThan(zone.lowerBound, search.lowerBound)
        let decide = try XCTUnwrap(miss.range(of: "switch EditedOccurrenceAddress.miss(for: call, matches: matches, identifier: id, requested: date, zone: timeZone ?? .current) {"))
        let notFound = try XCTUnwrap(miss.range(of: ".eventNotFound(identifier: detail)"))
        XCTAssertLessThan(search.lowerBound, decide.lowerBound)
        XCTAssertLessThan(decide.lowerBound, notFound.lowerBound)
        XCTAssertTrue(miss.contains("case .refusal(let reason): return call == .moveRow ? .moveRefused(reason: reason) : .occurrenceAddressRefused(reason: reason)"), miss)
        XCTAssertTrue(miss.contains("case .notFound(let detail): return call == .moveRow ? .moveRefused(reason: Self.noOccurrenceOnDateReason) : .eventNotFound(identifier: detail)"), miss)

        let edited = try body(of: "func editedOccurrences(")
        XCTAssertTrue(edited.contains("EditedOccurrenceAddress.matches(onDay: dayReadings(containing: date, in: timeZone), listed: seriesReadings(of: series, id: id),"), edited)
        XCTAssertTrue(edited.contains("seriesID: id, seriesIsAllDay: series.isAllDay, requested: date, zone: timeZone ?? .current)"), edited)

        let day = try body(of: "func dayReadings(")
        XCTAssertTrue(day.contains("OccurrenceDay.candidateWindow(containing: date, in: timeZone)"), day)
        XCTAssertTrue(day.contains("calendars: nil)"), day)
        for code in [miss, edited, day] {
            for write in ["eventStore.save(", "eventStore.remove(", "eventStore.commit(", "FileHandle.standardError", "fputs("] {
                XCTAssertFalse(code.contains(write), write)
            }
        }
    }

    /// The lookup itself is as it was: by the exact identifier, for an occurrence starting on the day.
    func testTheLookupStillTestsTheExactIdentifier() throws {
        let find = try body(of: "func findOccurrence(")
        XCTAssertTrue(find.contains("FutureDeletionCoverage.isRequested(eventIdentifier: event.eventIdentifier, occurrenceDate: event.occurrenceDate, identifier: identifier, slot: slot)"), find)
        XCTAssertTrue(find.contains("OccurrenceDay.startsOnRequestedDay(occurrenceStart: event.startDate, isAllDay: event.isAllDay, requested: date, in: timeZone)"), find)
        XCTAssertFalse(find.contains("EditedOccurrenceAddress"), find)
        // The two callers this change leaves alone still call it directly.
        XCTAssertFalse(try body(of: "func deleteEventsBatch(").contains("occurrenceMissError("))
        XCTAssertFalse(try body(of: "func applyExclusions(").contains("EditedOccurrenceAddress"))
    }

    /// #534: the exclusion check of `createEvent` asks whether the date still holds an occurrence,
    /// with the lookup's answer and the day's events, and throws the conflict.
    func testTheExclusionCheckCountsAnEditedOccurrenceOnTheDay() throws {
        let create = try body(of: "func createEvent(")
        let check = "for date in excluded { if EditedOccurrenceAddress.stillPresent( lookupHit: findOccurrence(identifier: existingId, on: date, in: tz) != nil, onDay: dayReadings(containing: date, in: tz), seriesID: existingId, requested: date, zone: tz ?? .current) { throw EventKitError.exclusionConflict("
        XCTAssertTrue(create.contains(check), create)
        XCTAssertEqual(count("findOccurrence(", in: create), 1)
        // Only the day is read: the series is not listed in the create path.
        XCTAssertFalse(create.contains("seriesReadings("), create)
        XCTAssertFalse(create.contains("editedOccurrences("), create)
    }

    /// #535: the not-found text is built by the formatter; the date's own description is not
    /// interpolated into it any more.
    func testTheNotFoundTextNoLongerInterpolatesTheDate() throws {
        let source = SourceScan.strippingComments(try manager())
        XCTAssertFalse(source.contains("(no occurrence on \\(date))"), "the UTC description of the date")
        XCTAssertEqual(count("no occurrence on", in: source), 0)
        let address = SourceScan.strippingComments(try SourcePins.source("EventKit/EditedOccurrenceAddress.swift"))
        XCTAssertEqual(count("(no occurrence on \\(day(requested, in: zone)))", in: address), 1)
    }

    /// The span `future` route is written once, in `DetachedOccurrenceSpan`, and read from there by
    /// both refusals; a copy in the new text could drift from the #416 text.
    func testTheSpanFutureRouteIsWrittenOnce() throws {
        let phrase = "for the later ones the id list_events shows"
        var total = 0
        for file in try SourceScan.swiftFiles() {
            total += count(phrase, in: SourceScan.strippingComments(try String(contentsOf: file, encoding: .utf8)))
        }
        XCTAssertEqual(total, 1)
        XCTAssertEqual(count(phrase, in: SourceScan.strippingComments(try SourcePins.source("EventKit/DetachedOccurrenceSpan.swift"))), 1)
        let address = SourceScan.strippingComments(try SourcePins.source("EventKit/EditedOccurrenceAddress.swift"))
        XCTAssertGreaterThanOrEqual(count("DetachedOccurrenceSpan.laterOccurrencesRoute", in: address), 1)
        // The new type writes nothing anywhere: no log line can carry an identifier.
        for write in ["FileHandle.standardError", "fputs(", "print(", "writeFailureLog(", "NSLog("] {
            XCTAssertFalse(address.contains(write), write)
        }
    }

    /// The listing the search reads is the one the other checks read, exposed without a change.
    func testTheListingIsExposedWithoutAChange() throws {
        let source = try SourcePins.source("EventKit/FirstRemainingOccurrence.swift")
        let readings = SourceScan.collapsingWhitespace(try XCTUnwrap(SourcePins.body(of: "func seriesReadings(", in: source)))
        XCTAssertTrue(readings.contains("seriesOccurrences(of: stale, id: id)?.0.map(EditedOccurrenceAddress.Reading.init)"), readings)
    }

    // MARK: - Documents

    /// Each phrase once in its document (a phrase that could occur twice survives the removal of the
    /// passage it is meant to hold).
    func testTheDocumentsDescribeTheRefusalOnce() throws {
        let pins: [(file: String, phrases: [String])] = [
            ("README.md", ["the series' identifier and that day no longer address it",
                           "an occurrence edited on its own that starts on an excluded date is a conflict",
                           "(no occurrence on 2026-12-21)"]),
            ("README_zh-TW.md", ["系列識別碼加那一天已經指不到它",
                                 "在排除日開始、被單獨修改過的場次算衝突",
                                 "(no occurrence on 2026-12-21)"]),
            ("CHANGELOG.md", ["A series' identifier and a day no longer answer not found for an occurrence edited on its own",
                              "an excluded date that still holds an occurrence edited on its own is a conflict",
                              "The not-found answer of `update_event` and `delete_event` prints the requested day, not a UTC instant"]),
            (".claude/rules/mcp-binary-version-testing.md", ["## Release gate：系列識別碼加日期指到被單獨修改過的場次（#532、#534、#535）",
                                                             "這個呼叫會被 #532 的訊息拒絕"]),
        ]
        for pin in pins {
            let text = try repoFile(pin.file)
            for phrase in pin.phrases {
                XCTAssertEqual(count(phrase, in: text), 1, "\(pin.file): \(phrase)")
            }
        }
    }
}
