import CoreLocation
import EventKit
import Foundation

/// #228 / #230 — VALUE snapshot of an EKAlarm, shared by `EventSnapshot`, `ReminderSnapshot`
/// and the event copy path. Recording an alarm as its `relativeOffset` alone turned
/// absolute-date and location alarms (both report offset 0) into alarms at the start or due
/// time, and email alarms into display alarms.
///
/// No EventKit object is kept: `EKAlarm.copy()` of an alarm fetched through another
/// `EKEventStore` aborts the process when it is added (checked on device), and stored rule
/// objects already broke undo once (#191). What cannot be rebuilt in Swift on macOS (a
/// procedure alarm's URL) is not carried: `restore` leaves such an alarm in place while it
/// is unchanged, and a rebuilt or copied one becomes a display alarm at the same time.
struct AlarmSnapshot: Hashable {
    struct Location: Hashable {
        let title: String?
        let latitude: Double?
        let longitude: Double?
        let radius: Double
    }

    let absoluteDate: Date?
    let relativeOffset: TimeInterval
    let location: Location?
    let proximity: EKAlarmProximity
    let emailAddress: String?
    let soundName: String?

    init(from alarm: EKAlarm) {
        absoluteDate = alarm.absoluteDate
        relativeOffset = alarm.relativeOffset
        location = alarm.structuredLocation.map {
            Location(title: $0.title,
                     latitude: $0.geoLocation?.coordinate.latitude,
                     longitude: $0.geoLocation?.coordinate.longitude,
                     radius: $0.radius)
        }
        proximity = alarm.proximity
        emailAddress = alarm.emailAddress
        soundName = alarm.soundName
    }

    private init(absoluteDate: Date?, relativeOffset: TimeInterval, location: Location?,
                 proximity: EKAlarmProximity, emailAddress: String?, soundName: String?) {
        self.absoluteDate = absoluteDate
        self.relativeOffset = relativeOffset
        self.location = location
        self.proximity = proximity
        self.emailAddress = emailAddress
        self.soundName = soundName
    }

    /// The same alarm at another time.
    private func timed(absoluteDate: Date?, relativeOffset: TimeInterval) -> AlarmSnapshot {
        AlarmSnapshot(absoluteDate: absoluteDate, relativeOffset: relativeOffset, location: location,
                      proximity: proximity, emailAddress: emailAddress, soundName: soundName)
    }

    /// #253 verify #1: the alarms for one occurrence copied out of its series (`span: this`).
    /// A series carries one absolute date per alarm, tied to the series start; copied as is,
    /// it would land before a later occurrence and never fire. With the series start known,
    /// the alarm keeps its distance from the start, measured from the occurrence instead.
    /// Without it, the alarm goes to the occurrence start as the copy did before #230, and
    /// `absolute_alarms` is reported. Other alarms are unchanged.
    static func forSplitOccurrence(_ alarms: [AlarmSnapshot], occurrenceStart: Date,
                                   seriesStart: Date?) -> (alarms: [AlarmSnapshot], notCarriedOver: [String]) {
        var movedToStart = false
        let split = alarms.map { alarm -> AlarmSnapshot in
            guard let date = alarm.absoluteDate else { return alarm }
            guard let seriesStart else {
                movedToStart = true
                return alarm.timed(absoluteDate: nil, relativeOffset: 0)
            }
            return alarm.timed(absoluteDate: occurrenceStart.addingTimeInterval(date.timeIntervalSince(seriesStart)),
                               relativeOffset: 0)
        }
        return (split, movedToStart ? ["absolute_alarms"] : [])
    }

    /// A location alarm reads back with no absolute date and offset 0, so it is the attached
    /// location, not the time, that makes it one.
    func rebuild() -> EKAlarm {
        let alarm = absoluteDate.map { EKAlarm(absoluteDate: $0) } ?? EKAlarm(relativeOffset: relativeOffset)
        if let location {
            // A place without a name stays without one; "" would read back as a different snapshot.
            let structured = location.title.map(EKStructuredLocation.init(title:)) ?? EKStructuredLocation()
            if let latitude = location.latitude, let longitude = location.longitude {
                structured.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
            }
            structured.radius = location.radius
            alarm.structuredLocation = structured
        }
        alarm.proximity = proximity
        // Assigning an email address or a sound changes the alarm's type, so only when present.
        // EventKit keeps both on one alarm and reports it as an email alarm, whichever is set
        // last (checked on macOS 27; the header says each clears the other), so the order
        // below does not decide the type.
        if let emailAddress { alarm.emailAddress = emailAddress }
        if let soundName { alarm.soundName = soundName }
        return alarm
    }

    /// Makes `item`'s alarms equal `snapshots` as a multiset (EventKit returns alarms in no
    /// fixed order), touching only the alarms that differ: an alarm with no wanted snapshot
    /// left is removed, a wanted snapshot with no alarm left is rebuilt and added. An alarm
    /// equal to its snapshot stays the same object, so what no snapshot can rebuild (a
    /// procedure alarm's URL) survives a change to another alarm (#253 verify #5). Returns
    /// whether anything was written.
    @discardableResult
    static func restore(_ snapshots: [AlarmSnapshot], to item: EKCalendarItem) -> Bool {
        var unmatched = counts(snapshots)
        var surplus: [EKAlarm] = []
        for alarm in item.alarms ?? [] {
            let snapshot = AlarmSnapshot(from: alarm)
            if unmatched[snapshot, default: 0] > 0 {
                unmatched[snapshot, default: 0] -= 1
            } else {
                surplus.append(alarm)
            }
        }
        let missing = snapshots.filter { snapshot in
            guard unmatched[snapshot, default: 0] > 0 else { return false }
            unmatched[snapshot, default: 0] -= 1
            return true
        }
        guard !surplus.isEmpty || !missing.isEmpty else { return false }
        surplus.forEach(item.removeAlarm)
        missing.forEach { item.addAlarm($0.rebuild()) }
        return true
    }

    private static func counts(_ snapshots: [AlarmSnapshot]) -> [AlarmSnapshot: Int] {
        snapshots.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}
