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

    /// #253 verify round 2 (D1): the kinds of alarm in `alarms` that a calendar outside iCloud
    /// may refuse (unverified), in a fixed order: `location_alarms`, `email_alarms`,
    /// `alarm_sounds`. A copy that fails to save names them as a possible cause.
    static func kindsSomeCalendarsMayRefuse(_ alarms: [AlarmSnapshot]) -> [String] {
        var kinds: [String] = []
        if alarms.contains(where: { $0.location != nil }) { kinds.append("location_alarms") }
        if alarms.contains(where: { $0.emailAddress != nil }) { kinds.append("email_alarms") }
        if alarms.contains(where: { $0.soundName != nil }) { kinds.append("alarm_sounds") }
        return kinds
    }

    /// #253 verify round 2 (D2): the alarms for one occurrence copied out of its series
    /// (`span: this`). A series carries one date per absolute alarm, which a later occurrence
    /// has already passed, so the copy would get an alarm that never fires. The occurrence's
    /// own date would need the series start: Apple documents the event fetched by identifier
    /// as the first occurrence, iCloud was seen to report the series start (checked once, on
    /// device), other providers are unchecked, and a detached occurrence carries its own
    /// date. So an absolute alarm goes to the occurrence start,
    /// as every copied alarm did before #230, and `absolute_alarms` is reported. Other alarms
    /// are unchanged.
    static func forSplitOccurrence(_ alarms: [AlarmSnapshot]) -> (alarms: [AlarmSnapshot], notCarriedOver: [String]) {
        let split = alarms.map { $0.absoluteDate == nil ? $0 : $0.timed(absoluteDate: nil, relativeOffset: 0) }
        return (split, alarms.contains { $0.absoluteDate != nil } ? ["absolute_alarms"] : [])
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
