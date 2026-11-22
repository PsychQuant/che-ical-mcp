import XCTest
@testable import CheICalMCP

/// #543 fix round 1: every cell of {host east, UTC, west} × {all-day series, timed series with a zone,
/// timed series with none} × {plain, moved, made all-day, made timed, series converted after the edit,
/// series and occurrence converted after the edit} × {series readable, not}, against `main`'s check
/// (copied below as the oracle) and against the day that is right for the way the `/RID=` was written.
///
/// The way the digits were written follows the series when the occurrence was first edited (#539 cell
/// R2): an all-day series writes the floating date (00:00 UTC of the day), a timed series with a zone
/// the instant, and one without a zone its wall-clock time as if UTC (#539). The right original day is
/// the floating or wall-clock date, or the instant's day in the zone `occurrence_date` is read in (the
/// occurrence's, the host's for one without). The right days are that one and the day it starts on.
///
/// Pure: zones are parameters, so the result does not follow the process zone. Both readability
/// states go through the same comparison because there is no series lookup.
final class OccurrenceDateMatchCellTests: XCTestCase {
    private static let utc = TimeZone(identifier: "UTC")!
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private static let hosts = ["Asia/Taipei", "UTC", "America/Los_Angeles"]
    /// The occurrence's original civil day, 2026-12-28; a moved occurrence starts on 2026-12-30.
    private static let year = 2026, month = 12, original = 28, moved = 30

    private enum Written { case floating, instant, wallClock }
    private enum Kind: CaseIterable { case allDay, timedZoned, timedFloating }
    private enum State: String, CaseIterable {
        case plain, moved, madeAllDay, madeTimed, seriesConverted, bothConverted
    }

    private struct Cell {
        let name: String
        let host: TimeZone
        let start: Date
        let startIsAllDay: Bool
        let zone: TimeZone?
        let rid: Date
        let written: Written
    }

    private static func date(_ day: Int, hour: Int = 0, in zone: TimeZone) -> Date {
        Calendar.gregorian(in: zone).date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static func civil(_ date: Date, in zone: TimeZone) -> Int {
        Calendar.gregorian(in: zone).component(.day, from: date)
    }

    /// The hours of a timed slot: one before, one at and one after 00:00 UTC in the series' zone
    /// (Asia/Tokyo 07:00, 09:00, 12:00), and wall-clock 00:00, 07:00 and 20:00 for a floating series.
    private static func hours(_ kind: Kind, zoned: [Int]) -> [Int] {
        switch kind {
        case .allDay: return [0]
        case .timedZoned: return zoned
        case .timedFloating: return [0, 7, 20]
        }
    }

    private static func cells(kinds: [Kind] = Kind.allCases, seriesZone: TimeZone = tokyo, zonedHours: [Int] = [7, 9, 12]) -> [Cell] {
        var cells: [Cell] = []
        for name in hosts {
            let host = TimeZone(identifier: name)!
            for kind in kinds {
                for hour in hours(kind, zoned: zonedHours) {
                    let (rid, written): (Date, Written) = switch kind {
                    case .allDay: (date(original, in: utc), .floating)
                    case .timedZoned: (date(original, hour: hour, in: seriesZone), .instant)
                    case .timedFloating: (date(original, hour: hour, in: utc), .wallClock)
                    }
                    let seriesWasAllDay = kind == .allDay
                    for state in State.allCases {
                        // The occurrence as it is now: all-day or timed, on which day, in which zone.
                        let occurrenceAllDay: Bool
                        switch state {
                        case .plain, .moved: occurrenceAllDay = seriesWasAllDay
                        case .madeAllDay:
                            if seriesWasAllDay { continue }
                            occurrenceAllDay = true
                        case .madeTimed:
                            if !seriesWasAllDay { continue }
                            occurrenceAllDay = false
                        case .seriesConverted: occurrenceAllDay = seriesWasAllDay
                        case .bothConverted: occurrenceAllDay = !seriesWasAllDay
                        }
                        let day = state == .plain ? original : moved
                        let start: Date
                        let zone: TimeZone?
                        if occurrenceAllDay {
                            (start, zone) = (date(day, in: host), nil)
                        } else if kind == .timedZoned {
                            (start, zone) = (date(day, hour: hour, in: seriesZone), seriesZone)
                        } else if kind == .timedFloating {
                            (start, zone) = (date(day, hour: hour, in: host), nil)
                        } else {
                            (start, zone) = (date(day, hour: 10, in: host), host)   // an all-day series' occurrence made timed
                        }
                        for readable in [true, false] {
                            let label = "\(name) \(kind) \(hour)h \(state.rawValue) \(readable ? "readable" : "unreadable")"
                            cells.append(Cell(name: label, host: host, start: start, startIsAllDay: occurrenceAllDay, zone: zone,
                                              rid: rid, written: written))
                        }
                    }
                }
            }
        }
        return cells
    }

    /// `main`'s `occurrenceDateMatches` at `92d9b796`, with the process zone made a parameter.
    private static func mainAccepts(_ cell: Cell, _ requested: Date) -> Bool {
        let slot = UndoPostState.originalSlot(eventIdentifier: identifier(cell), externalIdentifier: nil, occurrenceDate: cell.start)
        return [cell.start, slot].contains {
            OccurrenceDay.startsOnRequestedDay(occurrenceStart: $0, isAllDay: cell.startIsAllDay, requested: requested,
                                               in: cell.zone, host: cell.host)
        }
    }

    private static func identifier(_ cell: Cell) -> String {
        "SERIES-543/RID=\(Int(cell.rid.timeIntervalSinceReferenceDate))"
    }

    private static func rightDays(_ cell: Cell) -> Set<Int> {
        let zone = cell.zone ?? cell.host
        let shown = cell.startIsAllDay ? civil(cell.start, in: cell.host) : civil(cell.start, in: zone)
        let original = cell.written == .instant ? civil(cell.rid, in: zone) : civil(cell.rid, in: utc)
        return [shown, original]
    }

    private struct Sets {
        var newlyWrong: Set<String> = []   // a wrong day taken that `main` refused
        var lost: Set<String> = []         // a right day refused that `main` took
        var fixed: Set<String> = []        // a right day taken that `main` refused
        var cellCount = 0
    }

    private static func sets(_ cells: [Cell]) -> Sets {
        var sets = Sets()
        for cell in cells {
            sets.cellCount += 1
            let right = rightDays(cell)
            for requestedDay in 25...31 {
                let requested = date(requestedDay, in: cell.zone ?? cell.host)
                let main = mainAccepts(cell, requested)
                let head = OccurrenceDateMatch.answer(
                    requested: requested, start: cell.start, startIsAllDay: cell.startIsAllDay, zone: cell.zone,
                    eventIdentifier: identifier(cell), externalIdentifier: nil, occurrenceDate: cell.start,
                    host: cell.host) == .matches
                let isRight = right.contains(requestedDay)
                let key = "\(cell.name) 12-\(requestedDay)"
                if head, !isRight, !main { sets.newlyWrong.insert(key) }
                if !head, isRight, main { sets.lost.insert(key) }
                if head, isRight, !main { sets.fixed.insert(key) }
            }
        }
        return sets
    }

    func testEveryCellAcceptsNoAdditionalDatesAndLosesOnlyTheListedOnes() {
        let sets = Self.sets(Self.cells())
        let (newlyWrong, lost, fixed, cellCount) = (sets.newlyWrong, sets.lost, sets.fixed, sets.cellCount)
        XCTAssertEqual(cellCount, 3 * (1 * 5 + 3 * 5 + 3 * 5) * 2)
        XCTAssertTrue(newlyWrong.isEmpty, "\(newlyWrong.sorted())")
        XCTAssertEqual(lost, ["America/Los_Angeles timedZoned 9h madeAllDay readable 12-27",
                              "America/Los_Angeles timedZoned 9h madeAllDay unreadable 12-27",
                              "America/Los_Angeles timedZoned 9h bothConverted readable 12-27",
                              "America/Los_Angeles timedZoned 9h bothConverted unreadable 12-27"], "\(lost.sorted())")
        XCTAssertTrue(fixed.isEmpty, "\(fixed.sorted())")
    }

    /// A timed series in a zone west of UTC whose slot is exactly 00:00 UTC (America/New_York 19:00
    /// on 2026-12-28 is 2026-12-29 00:00 UTC). The instant gives the 28th
    /// in the occurrence's zone and the date reading the 29th, so the right day `main` took is refused
    /// on every host for a timed occurrence, and on a host west of UTC for an all-day one. The class
    /// of the grid above, not only its Tokyo cell: 00:00 UTC digits compared in
    /// a zone where that instant is the day before (the occurrence's zone, the host's without one).
    func testASlotAtMidnightUTCInAZoneWestOfUTCIsRefusedWhereTheReadingIsUnknown() {
        let sets = Self.sets(Self.cells(kinds: [.timedZoned], seriesZone: TimeZone(identifier: "America/New_York")!, zonedHours: [19]))
        XCTAssertEqual(sets.cellCount, 3 * 5 * 2)
        XCTAssertTrue(sets.newlyWrong.isEmpty, "\(sets.newlyWrong.sorted())")
        var lost: Set<String> = []
        for host in Self.hosts {
            lost.insert("\(host) timedZoned 19h moved readable 12-28")
            lost.insert("\(host) timedZoned 19h moved unreadable 12-28")
            lost.insert("\(host) timedZoned 19h seriesConverted readable 12-28")
            lost.insert("\(host) timedZoned 19h seriesConverted unreadable 12-28")
        }
        for state in ["madeAllDay", "bothConverted"] {
            for readable in ["readable", "unreadable"] {
                lost.insert("America/Los_Angeles timedZoned 19h \(state) \(readable) 12-28")
            }
        }
        XCTAssertEqual(sets.lost, lost, "\(sets.lost.sorted())")
        XCTAssertEqual(sets.fixed, [], "\(sets.fixed.sorted())")
    }
}
