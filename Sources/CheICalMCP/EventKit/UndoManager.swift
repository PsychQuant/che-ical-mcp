import EventKit
import Foundation

// MARK: - Snapshots

/// Snapshot of an EKEvent's properties for undo/redo restoration.
struct EventSnapshot {
    let title: String
    let startDate: Date
    let endDate: Date
    let calendarTitle: String
    let calendarSource: String?
    let notes: String?
    let location: String?
    let url: URL?
    let isAllDay: Bool
    let alarmOffsets: [TimeInterval]?
    let structuredLocationTitle: String?
    let structuredLocationLat: Double?
    let structuredLocationLon: Double?
    let structuredLocationRadius: Double?
    // Recurrence rules stored as raw EKRecurrenceRule for re-application
    let recurrenceRules: [EKRecurrenceRule]?
    let timeZone: TimeZone?

    init(from event: EKEvent) {
        self.title = event.title ?? ""
        self.startDate = event.startDate
        self.endDate = event.endDate
        self.calendarTitle = event.calendar.title
        self.calendarSource = event.calendar.source?.title
        self.notes = event.notes
        self.location = event.location
        self.url = event.url
        self.isAllDay = event.isAllDay
        self.alarmOffsets = event.alarms?.map { $0.relativeOffset }
        self.structuredLocationTitle = event.structuredLocation?.title
        self.structuredLocationLat = event.structuredLocation?.geoLocation?.coordinate.latitude
        self.structuredLocationLon = event.structuredLocation?.geoLocation?.coordinate.longitude
        self.structuredLocationRadius = event.structuredLocation?.radius
        self.recurrenceRules = event.recurrenceRules
        self.timeZone = event.timeZone
    }
}

/// Snapshot of an EKReminder's properties for undo/redo restoration.
struct ReminderSnapshot {
    let title: String
    let calendarTitle: String
    let calendarSource: String?
    let notes: String?
    let isCompleted: Bool
    let priority: Int
    let dueDateComponents: DateComponents?
    let alarmOffsets: [TimeInterval]?

    init(from reminder: EKReminder) {
        self.title = reminder.title ?? ""
        self.calendarTitle = reminder.calendar.title
        self.calendarSource = reminder.calendar.source?.title
        self.notes = reminder.notes
        self.isCompleted = reminder.isCompleted
        self.priority = reminder.priority
        self.dueDateComponents = reminder.dueDateComponents
        self.alarmOffsets = reminder.alarms?.map { $0.relativeOffset }
    }
}

// MARK: - Operations

/// A recorded mutation operation that can be undone/redone.
enum UndoOperation {
    case createEvent(id: String, title: String)
    case deleteEvent(snapshot: EventSnapshot)
    case updateEvent(id: String, oldSnapshot: EventSnapshot)
    case createReminder(id: String, title: String)
    case deleteReminder(snapshot: ReminderSnapshot)
    case updateReminder(id: String, oldSnapshot: ReminderSnapshot)
    case completeReminder(id: String, wasCompleted: Bool, title: String)
    case batch([UndoOperation])

    /// Human-readable description of this operation.
    var description: String {
        switch self {
        case .createEvent(_, let title):
            return "Created event: \(title)"
        case .deleteEvent(let snapshot):
            return "Deleted event: \(snapshot.title)"
        case .updateEvent(_, let old):
            return "Updated event: \(old.title)"
        case .createReminder(_, let title):
            return "Created reminder: \(title)"
        case .deleteReminder(let snapshot):
            return "Deleted reminder: \(snapshot.title)"
        case .updateReminder(_, let old):
            return "Updated reminder: \(old.title)"
        case .completeReminder(_, _, let title):
            return "Completed reminder: \(title)"
        case .batch(let ops):
            return "Batch (\(ops.count) operations)"
        }
    }
}

/// Timestamped record of an operation.
struct UndoRecord {
    let operation: UndoOperation
    let timestamp: Date

    init(_ operation: UndoOperation) {
        self.operation = operation
        self.timestamp = Date()
    }
}

// MARK: - UndoManager

/// In-memory undo/redo stack for calendar and reminder operations.
/// History is lost on server restart.
actor CalendarUndoManager {
    static let shared = CalendarUndoManager()

    private var undoStack: [UndoRecord] = []
    private var redoStack: [UndoRecord] = []
    private let maxStackSize = 50

    private init() {}

    /// Record a mutation. Clears the redo stack.
    func record(_ operation: UndoOperation) {
        undoStack.append(UndoRecord(operation))
        if undoStack.count > maxStackSize {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    /// Pop the most recent operation for undoing.
    func popUndo() -> UndoRecord? {
        guard let record = undoStack.popLast() else { return nil }
        redoStack.append(record)
        return record
    }

    /// Pop the most recent undone operation for redoing.
    func popRedo() -> UndoRecord? {
        guard let record = redoStack.popLast() else { return nil }
        undoStack.append(record)
        return record
    }

    /// Get undo history (newest first).
    func history() -> [(index: Int, description: String, timestamp: Date)] {
        return undoStack.enumerated().reversed().map { (index, record) in
            (index: index, description: record.operation.description, timestamp: record.timestamp)
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoCount: Int { undoStack.count }
    var redoCount: Int { redoStack.count }
}
