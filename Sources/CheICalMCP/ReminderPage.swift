import EventKit
import Foundation

/// Only inexpensive fields required to select a page. Conformance never sends
/// an EventKit object across the actor: selection and copying are synchronous.
protocol ReminderSelectable {
    var selectionTitle: String? { get }
    var notes: String? { get }
    var isCompleted: Bool { get }
    var priority: Int { get }
    var dueDateComponents: DateComponents? { get }
    var creationDate: Date? { get }
}
extension EKReminder: ReminderSelectable { var selectionTitle: String? { title } }
extension ReminderReadSnapshot: ReminderSelectable { var selectionTitle: String? { title } }

struct ReminderPage: Sendable {
    let reminders: [ReminderReadSnapshot]
    let totalFetched: Int
    let totalAfterFilter: Int
    let referenceDate: Date
}

struct ReminderPageQuery: Sendable {
    var overdueOnly = false
    var sort: String? = nil
    var tag: String? = nil
    var limit: Int? = nil
    var now: Date? = nil

    func page<T: ReminderSelectable>(_ input: [T], snapshot: (T) -> ReminderReadSnapshot) -> ReminderPage {
        let referenceDate = now ?? Date()
        var selected = input.filter { value in
            if overdueOnly && (value.isCompleted || !(safeDateFromComponents(value.dueDateComponents).map { $0 < referenceDate } ?? false)) {
                return false
            }
            if let tag {
                let normalized = tag.hasPrefix("#") ? String(tag.dropFirst()) : tag
                return ReminderTags.extract(from: value.notes).tags.contains {
                    $0.caseInsensitiveCompare(normalized) == .orderedSame
                }
            }
            return true
        }
        let count = selected.count
        if let sort {
            selected.sort { a, b in
                switch sort {
                case "priority": return (a.priority == 0 ? Int.max : a.priority) < (b.priority == 0 ? Int.max : b.priority)
                case "title": return (a.selectionTitle ?? "").localizedCaseInsensitiveCompare(b.selectionTitle ?? "") == .orderedAscending
                case "creation_date": return (a.creationDate ?? .distantPast) < (b.creationDate ?? .distantPast)
                default:
                    let first = safeDateFromComponents(a.dueDateComponents)
                    let second = safeDateFromComponents(b.dueDateComponents)
                    guard let first else { return false }
                    guard let second else { return true }
                    return first < second
                }
            }
        }
        let page = limit.map { Array(selected.prefix(max(0, $0))) } ?? selected
        return ReminderPage(reminders: page.map(snapshot), totalFetched: input.count, totalAfterFilter: count, referenceDate: referenceDate)
    }
}

extension ReminderReadSource {
    func listReminderPage(completed: Bool?, calendarName: String?, calendarSource: String?, query: ReminderPageQuery) async throws -> ReminderPage {
        let values = try await listReminderSnapshots(completed: completed, calendarName: calendarName, calendarSource: calendarSource)
        return query.page(values) { $0 }
    }
    func searchReminderPage(keywords: [String], matchMode: String, calendarName: String?, calendarSource: String?, completed: Bool?, query: ReminderPageQuery) async throws -> ReminderPage {
        let values = try await searchReminderSnapshots(keywords: keywords, matchMode: matchMode, calendarName: calendarName, calendarSource: calendarSource, completed: completed)
        return query.page(values) { $0 }
    }
}
