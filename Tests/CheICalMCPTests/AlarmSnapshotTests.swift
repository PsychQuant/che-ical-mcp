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

    /// The property #236's post-state check relies on: reading a rebuilt alarm gives back
    /// the snapshot it was rebuilt from.
    func testEveryKindRebuildsToAnEqualSnapshot() {
        for alarm in [EKAlarm(relativeOffset: -900), EKAlarm(absoluteDate: absoluteDate), locationAlarm(), emailAlarm()] {
            let snapshot = AlarmSnapshot(from: alarm)
            XCTAssertEqual(AlarmSnapshot(from: snapshot.rebuild()), snapshot)
        }
    }

    func testAbsoluteAndLocationAlarmsHaveDistinctSnapshots() {
        let kinds = [EKAlarm(relativeOffset: 0), EKAlarm(absoluteDate: absoluteDate), locationAlarm()].map(AlarmSnapshot.init(from:))
        XCTAssertEqual(Set(kinds).count, 3)
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
