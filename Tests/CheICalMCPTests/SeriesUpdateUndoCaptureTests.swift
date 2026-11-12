import EventKit
import XCTest
@testable import CheICalMCP

/// #263: the series' exceptions are listed three times for one whole-series update record (before the
/// save, after it, and at undo time) and once more after the restore. They compare only when listed
/// over the same windows, so the later listings take the recorded windows instead of placing a new
/// one around `now` (`SeriesExceptionsUndo.capture(of:in:windows:)`).
final class SeriesUpdateUndoCaptureTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let s0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func s(_ week: Int) -> Date { s0.addingTimeInterval(Double(week) * 7 * day) }

    func testTheRecordedWindowsAreListedAgainWhateverTheTime() throws {
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Weekly", slots: [s(0), s(1), s(3)])
        let rid = "/RID=\(Int(s(1).timeIntervalSinceReferenceDate))"
        occurrences[1].id = "S" + rid
        occurrences[1].external = "X-S" + rid
        occurrences[1].detached = true
        store.seriesEnd = .endsAt(s(3))
        let recorded = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: s0))

        let later = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, windows: recorded.windows))

        XCTAssertEqual(later.windows, recorded.windows)
        XCTAssertEqual(later.keptSlots, [s(0), s(3)])
        XCTAssertEqual(later.detached.map(\.slot), [s(1)])
        XCTAssertTrue(SeriesUpdateUndo.covers(later, firstStart: s(0), end: .endsAt(s(3))))
        // The window placed around a later `now` can be another one (here, for the same occurrences
        // read as a series with no end).
        store.seriesEnd = .open
        let placedLater = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: s(100)))
        XCTAssertNotEqual(placedLater.windows, recorded.windows)
    }

    func testAnOccurrenceDeletedSinceShowsInTheListingOverTheRecordedWindows() throws {
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Weekly", slots: [s(0), s(1), s(2)])
        store.seriesEnd = .endsAt(s(2))
        let recorded = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, now: s0))
        try store.remove(occurrences[1], span: .thisEvent)

        let later = try XCTUnwrap(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, windows: recorded.windows))

        XCTAssertEqual(SeriesUpdateUndo.diff(recorded: recorded, current: later).deleted, [s(1)])
    }

    func testNoWindowsOrNoCalendarListsNothing() {
        let store = FakeSeriesExceptionsStore()
        let occurrences = store.addSeries(id: "S", calendar: "C", title: "Weekly", slots: [s(0)])
        XCTAssertNil(SeriesExceptionsUndo.capture(of: occurrences[0], in: store, windows: []))
        let noCalendar = FakeSeriesExceptionsStore.Event(id: "S", title: "Weekly", start: s0, hasRules: true)
        XCTAssertNil(SeriesExceptionsUndo.capture(of: noCalendar, in: store, windows: [DateInterval(start: s0, duration: day)]))
        XCTAssertEqual(store.log, [], "nothing listed")
    }
}
