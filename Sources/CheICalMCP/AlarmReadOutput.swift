import EventKit
import Foundation

/// #240: the `alarms` list of the read output, one mapping for reminders (#231) and events, so the
/// keys, the sign of `minutes_before`, the order and the non-finite filter cannot differ between them.
enum AlarmReadOutput {
    /// The time-based alarms of an item. A location alarm reads back with `absoluteDate` nil and
    /// `relativeOffset` 0, so it is set aside before the absolute / relative split (#231): reminders
    /// report it as `location_trigger`, events leave it out.
    static func timeBased(_ alarms: [EKAlarm]?) -> [ReminderReadSnapshot.Alarm] {
        (alarms ?? []).compactMap { alarm in
            guard alarm.structuredLocation == nil else { return nil }
            if let date = alarm.absoluteDate { return .absolute(date) }
            return .relative(seconds: alarm.relativeOffset)
        }
    }

    /// `[{"kind": "relative", "minutes_before": n}]` (positive = before the item's date, the sense of
    /// `alarms_minutes_offsets`) or `[{"kind": "absolute", "absolute_date": …, "absolute_date_local": …}]`,
    /// sorted and filtered by `ReminderReadSnapshot.Alarm.listed`. The two formatters are the
    /// caller's: the UTC one and the one its other `*_local` strings use.
    static func dictionaries(_ alarms: [ReminderReadSnapshot.Alarm], absolute: (Date) -> String,
                             absoluteLocal: (Date) -> String) -> [[String: Any]] {
        ReminderReadSnapshot.Alarm.listed(alarms).map { alarm -> [String: Any] in
            switch alarm {
            case .relative(let seconds):
                // EventKit: negative is before. `+ 0` turns -0.0 into 0.
                return ["kind": "relative", "minutes_before": -seconds / 60 + 0]
            case .absolute(let date):
                return ["kind": "absolute", "absolute_date": absolute(date), "absolute_date_local": absoluteLocal(date)]
            }
        }
    }
}
