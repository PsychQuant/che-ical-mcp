import EventKit
import XCTest
@testable import CheICalMCP

/// #328: `delete_calendar` with `require_empty` checks the calendar first. Events are searched over
/// a stated window, span by span (`EventRangeQuery`), and the search stops at the first span that
/// holds any; a reminder list is counted whole. Closures stand in for EventKit.
final class CalendarEmptinessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    func testTheWindowIsCenteredOnNow() {
        let window = CalendarEmptiness.window(now: now)
        XCTAssertEqual(window.start, now.addingTimeInterval(-Double(CalendarEmptiness.windowDaysEachSide) * day))
        XCTAssertEqual(window.end, now.addingTimeInterval(Double(CalendarEmptiness.windowDaysEachSide) * day))
    }

    /// PR #413 verify r1: every query, overlap second included, is one EventKit query
    /// (`EventRangeQuery.spans` gives one span for it) and stays clear of the four-year cut
    /// (EventKit cut at start + 1461 days, #325), also across 1900, 2100 and 2200, which have no
    /// leap day; the queries cover the window with no gap.
    func testEveryProbeQueryIsOneEventKitQueryWithMarginAcrossCenturyYears() throws {
        var queried: [(Date, Date)] = []
        let window = CalendarEmptiness.window(now: now)
        _ = try CalendarEmptiness.firstEvents(in: window) { from, to in queried.append((from, to)); return 0 }
        let gregorian = Calendar(identifier: .gregorian)
        var crossed = Set<Int>()
        for (index, (from, to)) in queried.enumerated() {
            XCTAssertEqual(try EventRangeQuery.spans(from: from, to: to).count, 1, "query \(index) is one EventKit query")
            XCTAssertLessThanOrEqual(to.timeIntervalSince(from), Double(EventRangeQuery.maxSpanDays) * day, "query \(index)")
            XCTAssertLessThan(to.timeIntervalSince(from), Double(EventRangeQuery.previousCutDays - 1) * day, "a day of margin, query \(index)")
            for year in [1900, 2100, 2200] {
                let jan = gregorian.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: year, month: 1, day: 1))!
                if from < jan && jan < to { crossed.insert(year) }
            }
            if index > 0 { XCTAssertEqual(from, queried[index - 1].1.addingTimeInterval(-1), "no gap, one second of overlap") }
        }
        XCTAssertEqual(crossed, [1900, 2100, 2200], "the window's queries cross the years without a leap day")
        XCTAssertEqual(queried.first?.0, window.start)
        XCTAssertEqual(queried.last?.1, window.end)
    }

    /// PR #413 verify r1: a calendar that allows neither events nor reminders is not claimed empty.
    func testACalendarThatHoldsNeitherKindIsRefused() {
        XCTAssertThrowsError(try CalendarEmptiness.checkKinds(holdsEvents: false, holdsReminders: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Nothing was deleted"), error.localizedDescription)
        }
        XCTAssertNoThrow(try CalendarEmptiness.checkKinds(holdsEvents: true, holdsReminders: false))
        XCTAssertNoThrow(try CalendarEmptiness.checkKinds(holdsEvents: false, holdsReminders: true))
    }

    func testAnEmptyCalendarIsSearchedThroughTheWholeWindow() throws {
        var queried: [(Date, Date)] = []
        let window = CalendarEmptiness.window(now: now)
        let found = try CalendarEmptiness.firstEvents(in: window) { from, to in queried.append((from, to)); return 0 }
        XCTAssertNil(found)
        XCTAssertEqual(queried.count, CalendarEmptiness.probeSpans(of: window).count)
        XCTAssertEqual(queried.first?.0, window.start)
        XCTAssertEqual(queried.last?.1, window.end)
        // A span after the first is queried from one second before its start, as `collect` does.
        XCTAssertEqual(queried[1].0, queried[0].1.addingTimeInterval(-1))
    }

    func testTheSearchStopsAtTheFirstSpanThatHoldsEvents() throws {
        var queried = 0
        let window = CalendarEmptiness.window(now: now)
        let found = try XCTUnwrap(try CalendarEmptiness.firstEvents(in: window) { _, _ in
            queried += 1
            return queried == 3 ? 2 : 0
        })
        XCTAssertEqual(queried, 3)
        XCTAssertEqual(found.atLeast, 2)
        XCTAssertEqual(found.span, CalendarEmptiness.probeSpans(of: window)[2])
    }

    func testAnEventCalendarWithEventsIsRefusedWithTheWindowAndALowerBound() throws {
        let window = CalendarEmptiness.window(now: now)
        do {
            try CalendarEmptiness.checkEvents(window: window, count: { _, _ in 3 })
            XCTFail("must refuse")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(error is EventKitError, "\(error)")
            XCTAssertTrue(text.contains("at least 3 event"), text)
            XCTAssertTrue(text.contains("Nothing was deleted"), text)
            XCTAssertTrue(text.contains(EventRangeQuery.localText(window.start)) && text.contains(EventRangeQuery.localText(window.end)), text)
            XCTAssertTrue(text.contains("lower bound"), text)
        }
        XCTAssertNoThrow(try CalendarEmptiness.checkEvents(window: window, count: { _, _ in 0 }))
    }

    /// PR #413 verify r1, 1: an event read that cannot answer refuses (fail-closed), it is never
    /// read as empty.
    func testAnEventReadThatFailsRefusesInsteadOfPassing() {
        struct ReadFailed: Error {}
        XCTAssertThrowsError(try CalendarEmptiness.checkEvents(window: CalendarEmptiness.window(now: now),
                                                               count: { _, _ in throw ReadFailed() })) { error in
            XCTAssertTrue(error is ReadFailed, "\(error)")
        }
    }

    func testAReminderListIsCountedWhole() throws {
        XCTAssertThrowsError(try CalendarEmptiness.checkReminders(counted: 2, generationBefore: 1, generationAfter: 1)) { error in
            XCTAssertTrue(error.localizedDescription.contains("holds 2 reminder(s), completed ones included"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Nothing was deleted"), error.localizedDescription)
        }
        XCTAssertNoThrow(try CalendarEmptiness.checkReminders(counted: 0, generationBefore: 1, generationAfter: 1))
    }

    /// PR #413 verify r1, 1: a fetch that returned nothing (nil, it failed) is not an empty list.
    func testARemindersFetchThatFailedRefusesInsteadOfDeleting() {
        XCTAssertThrowsError(try CalendarEmptiness.checkReminders(counted: nil, generationBefore: 1, generationAfter: 1)) { error in
            XCTAssertTrue(error is EventKitError, "\(error)")
            XCTAssertTrue(error.localizedDescription.contains("could not be counted"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Nothing was deleted"), error.localizedDescription)
        }
    }

    /// PR #413 verify r1, 2: the reminder fetch suspends; a write this server committed meanwhile
    /// (the write generation moved) refuses, even when the count was 0.
    func testAWriteDuringTheReminderFetchRefuses() {
        XCTAssertThrowsError(try CalendarEmptiness.checkReminders(counted: 0, generationBefore: 4, generationAfter: 5)) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed while the list was being checked"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Nothing was deleted"), error.localizedDescription)
        }
    }

    // MARK: - wiring (PR #413 verify r1, 2)

    /// The check runs on the manager's actor: the event span loop is synchronous (no `await` in
    /// `CalendarEmptiness`), the only suspension between the start of the check and the removal is
    /// the reminder fetch, and the write generation is taken before it and compared after it,
    /// before `removeCalendar`.
    func testTheCheckRunsOnTheActorWithOneSuspensionAndAGenerationCompare() throws {
        let emptiness = try SourcePins.source("EventKit/CalendarEmptiness.swift")
        XCTAssertEqual(SourcePins.ranges(ofPattern: #"\basync\b|\bawait\b"#, in: SourcePins.code(emptiness)).count, 0,
                       "CalendarEmptiness has no async step, so it runs on its caller's actor")
        let body = try XCTUnwrap(SourcePins.body(of: "func deleteCalendar(identifier: String, requireEmpty: Bool = false)",
                                                 in: try SourcePins.source("EventKit/EventKitManager.swift")))
        let code = SourcePins.code(body)
        let check = try XCTUnwrap(SourcePins.ranges(of: "if requireEmpty {", in: code).first)
        let generation = try XCTUnwrap(SourcePins.ranges(of: "let generation = writeGeneration", in: code).first)
        let events = try XCTUnwrap(SourcePins.ranges(of: "CalendarEmptiness.checkEvents(", in: code).first)
        let fetch = try XCTUnwrap(SourcePins.ranges(of: "await countReminders(in: calendar)", in: code).first)
        let compare = try XCTUnwrap(SourcePins.ranges(of: "generationAfter: writeGeneration", in: code).first)
        let removal = try XCTUnwrap(SourcePins.ranges(of: "eventStore.removeCalendar(", in: code).first)
        XCTAssertTrue(check.lowerBound < generation.lowerBound && generation.lowerBound < events.lowerBound
                      && events.lowerBound < fetch.lowerBound && fetch.lowerBound < compare.lowerBound
                      && compare.lowerBound < removal.lowerBound, "generation, events, fetch, compare, removal, in that order")
        let awaits = SourcePins.ranges(ofPattern: #"\bawait\b"#, in: String(code[check.lowerBound..<removal.lowerBound]))
        XCTAssertEqual(awaits.count, 1, "the reminder fetch is the only suspension before the removal")
    }

    /// PR #413 security review: a writer that moved the generation late (in a `defer`, or after its
    /// own `await`) could commit during `deleteCalendar`'s reminder fetch and still pass the
    /// compare. The manager's store counts its own commits instead (`CountingEventStore`): the
    /// manager holds one, every write method is overridden to count in a `defer` and do nothing
    /// else, `writeGeneration` includes the count, and the only other stores the server makes are
    /// the setup's, the authorization default's and `NewObjectSave`'s read-only one.
    func testEveryCommitThroughTheManagersStoreMovesTheGenerationAtOnce() throws {
        let manager = try SourcePins.source("EventKit/EventKitManager.swift")
        XCTAssertEqual(SourcePins.ranges(of: "let eventStore: CountingEventStore", in: manager).count, 1)
        XCTAssertEqual(SourcePins.ranges(of: "let store = CountingEventStore()", in: manager).count, 1)
        let generation = try XCTUnwrap(SourcePins.body(of: "var writeGeneration: Int", in: manager))
        XCTAssertEqual(SourcePins.ranges(of: "eventStore.commitCount", in: generation).count, 1)

        let store = try SourcePins.source("EventKit/CountingEventStore.swift")
        let overrides = SourcePins.ranges(ofPattern: #"override func [a-zA-Z]+\("#, in: store)
        XCTAssertEqual(overrides.count, 9, "every EKEventStore write method: save/remove event (two each), save/remove reminder, save/remove calendar, commit")
        for method in ["override func save(_ event: EKEvent, span: EKSpan)", "override func save(_ event: EKEvent, span: EKSpan, commit: Bool)",
                       "override func remove(_ event: EKEvent, span: EKSpan)", "override func remove(_ event: EKEvent, span: EKSpan, commit: Bool)",
                       "override func save(_ reminder: EKReminder, commit: Bool)", "override func remove(_ reminder: EKReminder, commit: Bool)",
                       "override func saveCalendar(_ calendar: EKCalendar, commit: Bool)", "override func removeCalendar(_ calendar: EKCalendar, commit: Bool)",
                       "override func commit()"] {
            let body = try XCTUnwrap(SourcePins.body(of: method, in: store), method)
            let code = SourcePins.code(body).replacingOccurrences(of: "\n", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            XCTAssertTrue(code.hasSuffix("throws { defer { commitCount &+= 1 } try super.\(code.split(separator: "super.").last ?? "")"), "\(method): \(code)")
            XCTAssertEqual(code.components(separatedBy: "try ").count - 1, 1, "only the super call: \(method)")
            XCTAssertEqual(SourcePins.ranges(ofPattern: #"\bawait\b"#, in: body).count, 0, method)
        }

        // The other stores the server makes: none writes (a write through one would not be counted).
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/CheICalMCP")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        var made: [String] = []
        for file in files {
            let relative = String(file.path.dropFirst(sources.path.count + 1))
            let code = SourcePins.code(try String(contentsOf: file, encoding: .utf8))
            for _ in SourcePins.ranges(ofPattern: #"\bEKEventStore\(\)"#, in: code) { made.append(relative) }
        }
        XCTAssertEqual(made.sorted(), ["EventKit/AuthorizationStatusSource.swift", "EventKit/NewObjectSave.swift", "SetupRunner.swift"],
                       "a new EKEventStore elsewhere could write past the count")
    }

    /// The count moves on a write that throws, too (a save may throw after the store took it).
    func testTheStoreCountsAWriteThatThrows() {
        let store = Self.countingStore
        let before = store.commitCount
        XCTAssertThrowsError(try store.save(EKReminder(eventStore: store), commit: true), "a reminder with no list cannot be saved")
        XCTAssertEqual(store.commitCount, before + 1)
    }

    /// One store for the test target's process, as `SharedTestStore` (#283).
    private static let countingStore = CountingEventStore()

    func testTheGenerationIncludesRefreshMarks() throws {
        let mark = try XCTUnwrap(SourcePins.body(of: "func markNeedsRefresh()", in: try SourcePins.source("EventKit/EventKitManager.swift")))
        XCTAssertEqual(SourcePins.ranges(of: "refreshMarks &+= 1", in: mark).count, 1, "a stale mark moves the generation too")
        let generation = try XCTUnwrap(SourcePins.body(of: "var writeGeneration: Int", in: try SourcePins.source("EventKit/EventKitManager.swift")))
        XCTAssertEqual(SourcePins.ranges(of: "refreshMarks", in: generation).count, 1)
    }
}
