import CoreLocation
import EventKit
import XCTest
@testable import CheICalMCP

/// #228 / #230: undo and `copy_event` rebuild alarms from `AlarmSnapshot`. Recording an
/// alarm as its `relativeOffset` alone turned absolute-date and location alarms (both report
/// offset 0) into alarms at the start or due time, and email alarms into display alarms.
final class AlarmSnapshotTests: XCTestCase {
    private let store = EKEventStore()
    private let absoluteDate = Date(timeIntervalSince1970: 1_800_000_000)

    private func locationAlarm() -> EKAlarm {
        let place = EKStructuredLocation(title: "Office")
        place.geoLocation = CLLocation(latitude: 25.04, longitude: 121.61)
        place.radius = 150
        let alarm = EKAlarm()
        alarm.structuredLocation = place
        alarm.proximity = .enter
        return alarm
    }

    private func emailAlarm() -> EKAlarm {
        let alarm = EKAlarm(relativeOffset: -3600)
        alarm.emailAddress = "owner@example.com"
        return alarm
    }

    private func snapshots(_ item: EKCalendarItem) -> [AlarmSnapshot] {
        (item.alarms ?? []).map(AlarmSnapshot.init(from:))
    }

    // MARK: - rebuild

    func testRelativeAlarmRoundTrips() {
        let rebuilt = AlarmSnapshot(from: EKAlarm(relativeOffset: -900)).rebuild()
        XCTAssertNil(rebuilt.absoluteDate)
        XCTAssertEqual(rebuilt.relativeOffset, -900)
        XCTAssertNil(rebuilt.structuredLocation)
    }

    func testAbsoluteAlarmKeepsItsDate() {
        let rebuilt = AlarmSnapshot(from: EKAlarm(absoluteDate: absoluteDate)).rebuild()
        XCTAssertEqual(rebuilt.absoluteDate, absoluteDate, "an absolute alarm must not come back as offset 0")
    }

    func testLocationAlarmKeepsItsLocationAndProximity() {
        let rebuilt = AlarmSnapshot(from: locationAlarm()).rebuild()
        XCTAssertNotNil(rebuilt.structuredLocation, "a location alarm must not come back as a time alarm at offset 0")
        XCTAssertEqual(rebuilt.structuredLocation?.title, "Office")
        XCTAssertEqual(rebuilt.structuredLocation?.geoLocation?.coordinate.latitude, 25.04)
        XCTAssertEqual(rebuilt.structuredLocation?.geoLocation?.coordinate.longitude, 121.61)
        XCTAssertEqual(rebuilt.structuredLocation?.radius, 150)
        XCTAssertEqual(rebuilt.proximity, .enter)
        XCTAssertNil(rebuilt.absoluteDate)
    }

    func testEmailAlarmStaysAnEmailAlarm() {
        let rebuilt = AlarmSnapshot(from: emailAlarm()).rebuild()
        XCTAssertEqual(rebuilt.type, .email)
        XCTAssertEqual(rebuilt.emailAddress, "owner@example.com")
        XCTAssertEqual(rebuilt.relativeOffset, -3600)
    }

    func testSoundNameIsCarried() {
        let alarm = EKAlarm(relativeOffset: -7200)
        alarm.soundName = "Ping"
        XCTAssertEqual(AlarmSnapshot(from: alarm).rebuild().soundName, "Ping")
    }

    /// A place with coordinates but no name: `structuredLocation.title` reads back nil.
    private func untitledLocationAlarm() -> EKAlarm {
        let place = EKStructuredLocation()
        place.geoLocation = CLLocation(latitude: 25.04, longitude: 121.61)
        let alarm = EKAlarm()
        alarm.structuredLocation = place
        alarm.proximity = .leave
        return alarm
    }

    private func emailAndSoundAlarm() -> EKAlarm {
        let alarm = emailAlarm()
        alarm.soundName = "Ping"
        return alarm
    }

    /// The property #236's post-state check relies on: reading a rebuilt alarm gives back
    /// the snapshot it was rebuilt from.
    func testEveryKindRebuildsToAnEqualSnapshot() {
        for alarm in [EKAlarm(relativeOffset: -900), EKAlarm(absoluteDate: absoluteDate), locationAlarm(),
                      untitledLocationAlarm(), emailAlarm(), emailAndSoundAlarm()] {
            let snapshot = AlarmSnapshot(from: alarm)
            XCTAssertEqual(AlarmSnapshot(from: snapshot.rebuild()), snapshot)
        }
    }

    /// Round-1 verify #6: a location without a name came back named "".
    func testUntitledLocationStaysUntitled() {
        let rebuilt = AlarmSnapshot(from: untitledLocationAlarm()).rebuild()
        XCTAssertNotNil(rebuilt.structuredLocation)
        XCTAssertNil(rebuilt.structuredLocation?.title)
    }

    /// Round-1 verify #6, pinned: the header says setting a sound clears the email address,
    /// but EventKit (macOS 27) keeps both on one alarm and reports it as an email alarm,
    /// whichever is set last. `rebuild` sets the email address first, then the sound.
    func testEmailAndSoundOnOneAlarmBothComeBackAsAnEmailAlarm() {
        let snapshot = AlarmSnapshot(from: emailAndSoundAlarm())
        XCTAssertEqual(snapshot.emailAddress, "owner@example.com")
        XCTAssertEqual(snapshot.soundName, "Ping")

        let rebuilt = snapshot.rebuild()
        XCTAssertEqual(rebuilt.type, .email)
        XCTAssertEqual(rebuilt.emailAddress, "owner@example.com")
        XCTAssertEqual(rebuilt.soundName, "Ping")
    }

    func testAbsoluteAndLocationAlarmsHaveDistinctSnapshots() {
        let kinds = [EKAlarm(relativeOffset: 0), EKAlarm(absoluteDate: absoluteDate), locationAlarm()].map(AlarmSnapshot.init(from:))
        XCTAssertEqual(Set(kinds).count, 3)
    }

    // MARK: - split occurrence (#253 verify round 2, D2)

    /// `move_events_batch` with span 'this' copies one occurrence out of its series. A series
    /// carries one date per absolute alarm, which a later occurrence has already passed. The
    /// occurrence's own date cannot be worked out reliably (it needs the series start), so the
    /// alarm goes to the occurrence start, as every copied alarm did before #230, and says so.
    func testSplitPutsAnAbsoluteAlarmAtTheOccurrenceStartAndSaysSo() {
        let alarm = AlarmSnapshot(from: EKAlarm(absoluteDate: absoluteDate))

        let split = AlarmSnapshot.forSplitOccurrence([alarm, alarm])

        XCTAssertEqual(split.alarms.map(\.absoluteDate), [nil, nil])
        XCTAssertEqual(split.alarms.map(\.relativeOffset), [0, 0])
        XCTAssertEqual(split.notCarriedOver, ["absolute_alarms"])
    }

    func testSplitLeavesRelativeLocationAndEmailAlarmsAsTheyAre() {
        let alarms = [EKAlarm(relativeOffset: -900), locationAlarm(), emailAlarm()].map(AlarmSnapshot.init(from:))

        let split = AlarmSnapshot.forSplitOccurrence(alarms)

        XCTAssertEqual(split.alarms, alarms)
        XCTAssertEqual(split.notCarriedOver, [])
    }

    // MARK: - restore

    func testRestoreLeavesEqualAlarmsInPlaceWhateverTheirOrder() {
        let event = EKEvent(eventStore: store)
        event.addAlarm(EKAlarm(relativeOffset: -900))
        event.addAlarm(EKAlarm(absoluteDate: absoluteDate))
        let recorded = Array(snapshots(event).reversed())

        XCTAssertFalse(AlarmSnapshot.restore(recorded, to: event))
        XCTAssertEqual(Set(snapshots(event)), Set(recorded))
        XCTAssertEqual(event.alarms?.count, 2)
    }

    func testRestoreRewritesAlarmsThatDiffer() {
        let original = EKEvent(eventStore: store)
        [EKAlarm(absoluteDate: absoluteDate), locationAlarm(), emailAlarm(), EKAlarm(relativeOffset: -900)].forEach(original.addAlarm)
        let recorded = snapshots(original)

        let edited = EKEvent(eventStore: store)
        edited.addAlarm(EKAlarm(relativeOffset: 0))

        XCTAssertTrue(AlarmSnapshot.restore(recorded, to: edited))
        XCTAssertEqual(snapshots(edited).count, 4)
        XCTAssertEqual(Set(snapshots(edited)), Set(recorded))
    }

    /// Round-1 verify #5: when one alarm differs, only that alarm is rewritten. An alarm the
    /// snapshot cannot rebuild (a procedure alarm: its URL is not recorded) must survive an
    /// unrelated alarm change. `EKAlarm.url` cannot be set in Swift on macOS (the assignment
    /// is ignored), so the unchanged alarm's object identity stands in for its URL.
    func testRestoreKeepsTheUnchangedAlarmObjectWhenAnotherAlarmDiffers() {
        let event = EKEvent(eventStore: store)
        let unchanged = EKAlarm(relativeOffset: -900)
        event.addAlarm(unchanged)
        event.addAlarm(EKAlarm(relativeOffset: -60))
        let recorded = [AlarmSnapshot(from: EKAlarm(relativeOffset: -900)), AlarmSnapshot(from: locationAlarm())]

        XCTAssertTrue(AlarmSnapshot.restore(recorded, to: event))
        XCTAssertEqual(event.alarms?.count, 2)
        XCTAssertEqual(Set(snapshots(event)), Set(recorded))
        XCTAssertTrue(event.alarms?.contains { $0 === unchanged } ?? false,
                      "the alarm equal to its snapshot must stay in place, not be rebuilt")
    }

    /// Which of two equal alarms stays is not fixed (EventKit does not keep insertion order),
    /// but it is one of the originals, not a rebuilt one.
    func testRestoreRemovesOnlySurplusDuplicates() {
        let item = EKEvent(eventStore: store)
        let originals = [EKAlarm(relativeOffset: -900), EKAlarm(relativeOffset: -900)]
        originals.forEach(item.addAlarm)
        let recorded = [AlarmSnapshot(from: EKAlarm(relativeOffset: -900))]

        XCTAssertTrue(AlarmSnapshot.restore(recorded, to: item))
        XCTAssertEqual(item.alarms?.count, 1)
        XCTAssertTrue(originals.contains { $0 === item.alarms?.first })
    }

    func testRestoreCountsDuplicateAlarms() {
        let item = EKEvent(eventStore: store)
        item.addAlarm(EKAlarm(relativeOffset: -900))
        let recorded = [AlarmSnapshot(from: EKAlarm(relativeOffset: -900)), AlarmSnapshot(from: EKAlarm(relativeOffset: -900))]

        XCTAssertTrue(AlarmSnapshot.restore(recorded, to: item))
        XCTAssertEqual(item.alarms?.count, 2)
    }

    func testRestoringNoAlarmsClearsThem() {
        let item = EKEvent(eventStore: store)
        item.addAlarm(locationAlarm())

        XCTAssertTrue(AlarmSnapshot.restore([], to: item))
        XCTAssertEqual(item.alarms ?? [], [])
    }

    func testRestoreWorksOnReminders() {
        let reminder = EKReminder(eventStore: store)
        let recorded = [AlarmSnapshot(from: locationAlarm())]

        XCTAssertTrue(AlarmSnapshot.restore(recorded, to: reminder))
        XCTAssertEqual(snapshots(reminder), recorded)
    }
}
