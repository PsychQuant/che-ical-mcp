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
/// procedure alarm's URL) is not carried; `restore` keeps such alarms when they are unchanged.
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

    /// A location alarm reads back with no absolute date and offset 0, so it is the attached
    /// location, not the time, that makes it one.
    func rebuild() -> EKAlarm {
        let alarm = absoluteDate.map { EKAlarm(absoluteDate: $0) } ?? EKAlarm(relativeOffset: relativeOffset)
        if let location {
            let structured = EKStructuredLocation(title: location.title ?? "")
            if let latitude = location.latitude, let longitude = location.longitude {
                structured.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
            }
            structured.radius = location.radius
            alarm.structuredLocation = structured
        }
        alarm.proximity = proximity
        // Assigning an email address or a sound changes the alarm's type, so only when present.
        if let emailAddress { alarm.emailAddress = emailAddress }
        if let soundName { alarm.soundName = soundName }
        return alarm
    }

    /// Rewrites `item`'s alarms only when they differ from `snapshots`, compared as a multiset
    /// (EventKit returns alarms in no fixed order). Leaving equal alarms in place also keeps
    /// what no snapshot can rebuild. Returns whether the alarms were rewritten.
    @discardableResult
    static func restore(_ snapshots: [AlarmSnapshot], to item: EKCalendarItem) -> Bool {
        let current = (item.alarms ?? []).map(AlarmSnapshot.init(from:))
        guard counts(current) != counts(snapshots) else { return false }
        item.alarms?.forEach(item.removeAlarm)
        snapshots.forEach { item.addAlarm($0.rebuild()) }
        return true
    }

    private static func counts(_ snapshots: [AlarmSnapshot]) -> [AlarmSnapshot: Int] {
        snapshots.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }
}
