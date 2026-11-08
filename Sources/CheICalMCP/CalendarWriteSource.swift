import EventKit
import Foundation

/// What `create_calendar` and `update_calendar` report.
struct CalendarWriteValue: Sendable {
    let title: String
    let identifier: String
    let isDuplicate: Bool
    let storeDiffers: [String]
}

/// #449: the narrow seam `create_calendar` and `update_calendar` write through (CLAUDE.md "Test Seam
/// Convention"), so a handler test sees what reaches the write. Production passes nothing and gets
/// `EventKitManager.shared`.
protocol CalendarWriteSource: Sendable {
    func writeNewCalendar(title: String, entityType: EKEntityType, color: String?) async throws -> CalendarWriteValue
    func writeCalendarUpdate(identifier: String, title: String?, color: String?) async throws -> CalendarWriteValue
}

extension EventKitManager: CalendarWriteSource {
    func writeNewCalendar(title: String, entityType: EKEntityType, color: String?) async throws -> CalendarWriteValue {
        let result = try await createCalendar(title: title, entityType: entityType, color: color)
        // #273: a marker, so that undo after this does not revert an older operation in its place.
        // Recorded here, after `createCalendar` returned (its save path is pinned as is by
        // `NewObjectSaveTests`), and not for the existing calendar a title match returned: nothing
        // was created then.
        if !result.isDuplicate {
            await CalendarUndoManager.shared.record(.calendarOperation(kind: .created, title: result.calendar.title))
        }
        return CalendarWriteValue(title: result.calendar.title, identifier: result.calendar.calendarIdentifier,
                                  isDuplicate: result.isDuplicate, storeDiffers: result.storeDiffers)
    }

    func writeCalendarUpdate(identifier: String, title: String?, color: String?) async throws -> CalendarWriteValue {
        let calendar = try await updateCalendar(identifier: identifier, title: title, color: color)
        return CalendarWriteValue(title: calendar.title, identifier: calendar.calendarIdentifier,
                                  isDuplicate: false, storeDiffers: [])
    }
}
