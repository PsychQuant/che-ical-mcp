import EventKit
import XCTest
@testable import CheICalMCP

/// #275: delete-undo recreates a reminder on a new `EKReminder`, which starts floating
/// (`timeZone == nil`), and `ReminderSnapshot` does not record the item zone.
///
/// On device (2026-11-05, iCloud, one server process for delete → undo, read back from another
/// process): a reminder `update_reminder` zoned came back zoned, its due and start at the recorded
/// wall clock and zone; a date-only reminder came back date-only and floating. The zone comes from
/// the dates: `ReminderDateSync.restore` writes a zoned timed due through `writeZonedDue` (#251).
///
/// The first group pins the restored values through `apply(to:lists:for:now:)`, the entry
/// delete-undo uses. It cannot see the save: in memory a plain write of the zoned due zones the new
/// item as well (checked by replacing the `writeZonedDue` call in `restore` with a plain write:
/// these still pass), while the store keeps such a due floating (#237 on-device notes). The store
/// side rests on the device run above. The second group pins why the item zone is not recorded and written on top (the fix #275 proposed):
/// in memory, the shapes it was meant for either cannot hold a zone or move when given one.
final class ReminderSnapshotZoneTests: XCTestCase {
    /// Not the host zone of the machine these were first run on (Asia/Taipei), so a zone that came
    /// from `.current` cannot pass for the recorded one.
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private var store: EKEventStore { SharedTestStore.store }
    private lazy var list = EKCalendar(for: .reminder, eventStore: store)

    private func makeReminder() -> EKReminder {
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        return reminder
    }

    private func timed(_ zone: TimeZone?, day: Int, hour: Int) -> DateComponents {
        DateComponents(timeZone: zone, year: 2026, month: 11, day: day, hour: hour, minute: 0)
    }

    private func recreate(from snapshot: ReminderSnapshot) throws -> EKReminder {
        let recreated = makeReminder()
        try snapshot.apply(to: recreated, lists: [list], for: .recreateDeleted, now: now)
        return recreated
    }

    // MARK: - Delete-undo takes the zone from the dates

    /// The case seen on device: a zoned timed due zones the new item.
    func testDeleteUndoOfAZonedTimedDueComesBackInItsZone() throws {
        let original = makeReminder()
        original.dueDateComponents = timed(newYork, day: 20, hour: 8)
        original.timeZone = newYork
        let snapshot = ReminderSnapshot(from: original)

        let recreated = try recreate(from: snapshot)

        XCTAssertEqual(recreated.timeZone, newYork)
        XCTAssertEqual(recreated.dueDateComponents?.day, 20)
        XCTAssertEqual(recreated.dueDateComponents?.hour, 8)
        XCTAssertEqual(recreated.dueDateComponents?.timeZone, newYork)
    }

    /// Shape (a) of the diagnosis without a due: EventKit zones the item from the zoned start.
    func testDeleteUndoOfAZonedTimedStartWithoutADueComesBackInItsZone() throws {
        let original = makeReminder()
        original.startDateComponents = timed(newYork, day: 20, hour: 8)
        original.timeZone = newYork
        let snapshot = ReminderSnapshot(from: original)

        let recreated = try recreate(from: snapshot)

        XCTAssertEqual(recreated.timeZone, newYork)
        XCTAssertEqual(recreated.startDateComponents?.hour, 8)
        XCTAssertNil(recreated.dueDateComponents)
    }

    func testDeleteUndoKeepsAFloatingReminderFloating() throws {
        let original = makeReminder()
        original.startDateComponents = timed(nil, day: 20, hour: 8)
        original.dueDateComponents = timed(nil, day: 20, hour: 9)
        XCTAssertNil(original.timeZone, "precondition: floating")
        let snapshot = ReminderSnapshot(from: original)

        let recreated = try recreate(from: snapshot)

        XCTAssertNil(recreated.timeZone)
        XCTAssertEqual(recreated.dueDateComponents?.hour, 9)
        XCTAssertNil(recreated.dueDateComponents?.timeZone)
    }

    // MARK: - Why the item zone is not written on top

    /// Shape (a) with a date-only due: in memory the item cannot be given a zone at all, so a
    /// recorded zone would be nil and a written one would not stick. On device a date-only update
    /// left the item floating too (2026-11-05).
    func testAReminderWithADateOnlyDueTakesNoZone() {
        let reminder = makeReminder()
        reminder.dueDateComponents = DateComponents(year: 2026, month: 11, day: 21)
        reminder.startDateComponents = timed(newYork, day: 20, hour: 8)

        reminder.timeZone = newYork

        XCTAssertNil(reminder.timeZone)
    }

    /// Shape (b): a timed due without a zone. Giving the item a zone after writing it keeps the
    /// instant the floating due had in the host zone, not its wall clock, so writing a recorded
    /// zone on top would move the due by the difference between the host zone and the recorded
    /// one (in memory). With a zoned due, `writeZonedDue` keeps the wall clock (#237).
    func testGivingAZoneAfterAFloatingTimedDueKeepsTheHostInstantNotTheWallClock() throws {
        let floatingDue = timed(nil, day: 20, hour: 8)
        var host = Calendar(identifier: .gregorian)
        host.timeZone = .current
        let hostInstant = try XCTUnwrap(host.date(from: floatingDue))
        let reminder = makeReminder()
        reminder.dueDateComponents = floatingDue

        reminder.timeZone = newYork

        let due = try XCTUnwrap(reminder.dueDateComponents)
        XCTAssertEqual(due.timeZone, newYork)
        var zoned = Calendar(identifier: .gregorian)
        zoned.timeZone = newYork
        let instant = try XCTUnwrap(zoned.date(from: DateComponents(year: due.year, month: due.month, day: due.day,
                                                                    hour: due.hour, minute: due.minute)))
        XCTAssertEqual(instant, hostInstant, "the instant is kept")
        if TimeZone.current.secondsFromGMT(for: hostInstant) != newYork.secondsFromGMT(for: hostInstant) {
            XCTAssertNotEqual(due.hour, 8, "so the wall clock moves")
        }
    }
}
