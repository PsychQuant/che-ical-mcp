import EventKit
import Foundation

// MARK: - Snapshots

/// #191 — VALUE snapshot of an EKRecurrenceRule. The previous design stored the
/// raw EKRecurrenceRule object; after the original event was deleted that
/// reference went stale, and re-attaching it in applySnapshot made the save
/// fail (EKCADErrorDomain 1010, #186 on-device). Rebuilding a fresh rule from
/// plain values closes that class structurally.
struct RecurrenceRuleSnapshot {
    struct DayOfWeek {
        let day: Int        // EKWeekday rawValue
        let weekNumber: Int
    }
    let frequency: EKRecurrenceFrequency
    let interval: Int
    let daysOfTheWeek: [DayOfWeek]?
    let daysOfTheMonth: [Int]?
    let monthsOfTheYear: [Int]?
    let weeksOfTheYear: [Int]?
    let daysOfTheYear: [Int]?
    let setPositions: [Int]?
    let endDate: Date?
    let occurrenceCount: Int?

    init(from rule: EKRecurrenceRule) {
        self.frequency = rule.frequency
        self.interval = rule.interval
        self.daysOfTheWeek = rule.daysOfTheWeek?.map { DayOfWeek(day: $0.dayOfTheWeek.rawValue, weekNumber: $0.weekNumber) }
        self.daysOfTheMonth = rule.daysOfTheMonth?.map(\.intValue)
        self.monthsOfTheYear = rule.monthsOfTheYear?.map(\.intValue)
        self.weeksOfTheYear = rule.weeksOfTheYear?.map(\.intValue)
        self.daysOfTheYear = rule.daysOfTheYear?.map(\.intValue)
        self.setPositions = rule.setPositions?.map(\.intValue)
        self.endDate = rule.recurrenceEnd?.endDate
        // EKRecurrenceEnd.occurrenceCount is 0 when the end is date-based
        let count = rule.recurrenceEnd?.occurrenceCount ?? 0
        self.occurrenceCount = count > 0 ? count : nil
    }

    func rebuild() -> EKRecurrenceRule {
        var end: EKRecurrenceEnd?
        if let date = endDate {
            end = EKRecurrenceEnd(end: date)
        } else if let count = occurrenceCount {
            end = EKRecurrenceEnd(occurrenceCount: count)
        }
        return EKRecurrenceRule(
            recurrenceWith: frequency,
            interval: interval,
            daysOfTheWeek: daysOfTheWeek?.compactMap { d in
                EKWeekday(rawValue: d.day).map { EKRecurrenceDayOfWeek($0, weekNumber: d.weekNumber) }
            },
            daysOfTheMonth: daysOfTheMonth?.map(NSNumber.init),
            monthsOfTheYear: monthsOfTheYear?.map(NSNumber.init),
            weeksOfTheYear: weeksOfTheYear?.map(NSNumber.init),
            daysOfTheYear: daysOfTheYear?.map(NSNumber.init),
            setPositions: setPositions?.map(NSNumber.init),
            end: end
        )
    }
}

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
    // #191 — recurrence rules stored as VALUE snapshots (never raw objects)
    let recurrenceRules: [RecurrenceRuleSnapshot]?
    let timeZone: TimeZone?

    init(from event: EKEvent, includeRecurrence: Bool = true) {
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
        self.recurrenceRules = includeRecurrence ? event.recurrenceRules?.map(RecurrenceRuleSnapshot.init) : nil
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
    /// #196: restored by undo instead of letting EventKit re-stamp "now".
    let completionDate: Date?

    init(from reminder: EKReminder) {
        self.title = reminder.title ?? ""
        self.calendarTitle = reminder.calendar.title
        self.calendarSource = reminder.calendar.source?.title
        self.notes = reminder.notes
        self.isCompleted = reminder.isCompleted
        self.priority = reminder.priority
        self.dueDateComponents = reminder.dueDateComponents
        self.alarmOffsets = reminder.alarms?.map { $0.relativeOffset }
        self.completionDate = reminder.completionDate
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
    /// #196: `requestedCompleted` is replayed by redo (never inferred as !wasCompleted —
    /// that reopened an idempotently completed reminder); `completionDate` is the
    /// pre-write instant undo restores. Neither has a default: dropping them must not compile.
    case completeReminder(id: String, wasCompleted: Bool, requestedCompleted: Bool, completionDate: Date?, title: String, redoCompletionDate: Date?)
    case completeRecurringReminder(before: ReminderCompletionSnapshot, requestedCompleted: Bool, redoCompletionDate: Date?)
    case batch([UndoOperation])

    /// Human-readable description of this operation. **Surfaces verbatim
    /// through the `undo_history` MCP tool's response field**, so any
    /// user-controlled title here flows through the same wire path as
    /// `executeUndo`/`executeRedo` arms — and shares the same CWE-117
    /// log-injection surface. Each title interpolation must go through
    /// `EventKitErrorSanitizer.sanitizeForInterpolation` (#74 verify DA1).
    var description: String {
        switch self {
        case .createEvent(_, let title):
            return "Created event: \(EventKitErrorSanitizer.sanitizeForInterpolation(title))"
        case .deleteEvent(let snapshot):
            return "Deleted event: \(EventKitErrorSanitizer.sanitizeForInterpolation(snapshot.title))"
        case .updateEvent(_, let old):
            return "Updated event: \(EventKitErrorSanitizer.sanitizeForInterpolation(old.title))"
        case .createReminder(_, let title):
            return "Created reminder: \(EventKitErrorSanitizer.sanitizeForInterpolation(title))"
        case .deleteReminder(let snapshot):
            return "Deleted reminder: \(EventKitErrorSanitizer.sanitizeForInterpolation(snapshot.title))"
        case .updateReminder(_, let old):
            return "Updated reminder: \(EventKitErrorSanitizer.sanitizeForInterpolation(old.title))"
        case .completeReminder(_, _, _, _, let title, _):
            return "Completed reminder: \(EventKitErrorSanitizer.sanitizeForInterpolation(title))"
        case .completeRecurringReminder(let before, let requestedCompleted, _):
            let action = requestedCompleted ? "Completed" : "Reopened"
            return "\(action) recurring reminder: \(EventKitErrorSanitizer.sanitizeForInterpolation(before.title))"
        case .batch(let ops):
            return "Batch (\(ops.count) operations)"
        }
    }
}

/// Timestamped record of an operation.
struct UndoRecord {
    let id = UUID()
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
    private var activeHistoryID: UUID?

    /// Production code uses `shared`. The internal initializer is a test seam
    /// for the stack-discipline tests (`ReminderCompletionUndoTests`): nothing
    /// injects a manager into a handler, so a `*Source` protocol would have no
    /// consumer — the tests exercise this actor's own stack semantics.
    init() {}

    struct HistorySnapshot: Sendable {
        let entries: [(index: Int, id: String, description: String, timestamp: Date)]
        let undoCount: Int
        let redoCount: Int
    }
    struct DiscardResult: Sendable {
        let id: String
        let description: String
        let undoCount: Int
        let redoCount: Int
    }

    func historySnapshot() -> HistorySnapshot {
        HistorySnapshot(entries: history(), undoCount: undoStack.count, redoCount: redoStack.count)
    }

    func beginUndo() throws -> UndoRecord? {
        guard activeHistoryID == nil else { throw UndoHistoryError.busy }
        let record = popUndo()
        activeHistoryID = record?.id
        return record
    }
    func beginRedo() throws -> UndoRecord? {
        guard activeHistoryID == nil else { throw UndoHistoryError.busy }
        let record = popRedo()
        activeHistoryID = record?.id
        return record
    }
    func finishHistoryOperation(_ record: UndoRecord) {
        if activeHistoryID == record.id { activeHistoryID = nil }
    }
    func discardUndo(expectedID: UUID) throws -> DiscardResult {
        guard activeHistoryID == nil else { throw UndoHistoryError.busy }
        guard let record = undoStack.last else { throw UndoHistoryError.empty }
        guard record.id == expectedID else { throw UndoHistoryError.stale }
        undoStack.removeLast()
        return DiscardResult(id: record.id.uuidString, description: record.operation.description,
                             undoCount: undoStack.count, redoCount: redoStack.count)
    }

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
    /// #191 — a FAILED executeUndo must not consume the entry. Contract: call
    /// ONLY immediately after the corresponding popUndo threw during execution —
    /// popUndo moved the record to the redo stack, so drop that copy and
    /// re-append the record to the undo stack.
    func restoreFailedUndo(_ record: UndoRecord) {
        finishHistoryOperation(record)
        redoStack.removeAll { $0.id == record.id }
        undoStack.append(record)
    }

    /// #191 — symmetric restore for a failed executeRedo (same call contract).
    func restoreFailedRedo(_ record: UndoRecord) {
        finishHistoryOperation(record)
        undoStack.removeAll { $0.id == record.id }
        redoStack.append(record)
    }

    /// A record whose undo can never succeed (the target occurrence no longer
    /// exists under that identifier) must not be put back: re-appending it
    /// jams every older entry behind an always-failing head. Same call contract
    /// as `restoreFailedUndo` — only immediately after the popUndo that threw.
    func discardFailedUndo(_ record: UndoRecord) {
        finishHistoryOperation(record)
        // Destructive, so verify it is the record popUndo just moved: a
        // contract slip must not destroy an unrelated entry.
        if let top = redoStack.last, top.id == record.id { redoStack.removeLast() }
    }

    /// Symmetric discard for a permanently failed executeRedo.
    func discardFailedRedo(_ record: UndoRecord) {
        finishHistoryOperation(record)
        if let top = undoStack.last, top.id == record.id { undoStack.removeLast() }
    }

    func popRedo() -> UndoRecord? {
        guard let record = redoStack.popLast() else { return nil }
        undoStack.append(record)
        return record
    }

    /// Get undo history (newest first).
    func history() -> [(index: Int, id: String, description: String, timestamp: Date)] {
        return undoStack.enumerated().reversed().map { (index, record) in
            (index: index, id: record.id.uuidString, description: record.operation.description, timestamp: record.timestamp)
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoCount: Int { undoStack.count }
    var redoCount: Int { redoStack.count }
}

// MARK: - Undo failure classification

/// Thrown by executeUndo/executeRedo when the recorded target can no longer be
/// acted on and never will be (e.g. a recurring reminder's identifier now
/// resolves to a later occurrence). Distinct from transient failures such as
/// a store that cannot find the item right now, which keep their history
/// entry for a retry (#191).
///
/// `message` MUST be author-controlled literal text; any store-derived value
/// interpolated into it (today: the reminder title) MUST pass
/// `EventKitErrorSanitizer.sanitizeForInterpolation` first. That is the
/// condition under which this type conforms to `TrustedErrorMessage`.
struct UnrecoverableUndoError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Author-controlled message (the title is passed through
/// `sanitizeForInterpolation`), so it may reach the client verbatim — without
/// this the explicit permanent-failure message flattens to `error_unknown`.
extension UnrecoverableUndoError: TrustedErrorMessage {}

extension UndoOperation {
    /// The record for a completion write. A recurring snapshot gets the
    /// identity-guarded record only when it can ever match again
    /// (`isIdentifiable`); otherwise the legacy identifier-keyed record, which
    /// restores an unchanged item correctly instead of being discarded on its
    /// first undo with a misleading reason.
    static func forCompletion(before: ReminderCompletionSnapshot, requestedCompleted: Bool, savedTitle: String, savedCompletionDate: Date?) -> UndoOperation {
        if before.hasRecurrence && before.isIdentifiable {
            return .completeRecurringReminder(before: before, requestedCompleted: requestedCompleted, redoCompletionDate: savedCompletionDate)
        }
        return .completeReminder(id: before.id, wasCompleted: before.isCompleted, requestedCompleted: requestedCompleted,
                                 completionDate: before.completionDate, title: savedTitle, redoCompletionDate: savedCompletionDate)
    }
}

extension UndoOperation {
    /// The completion write an undo (`undo: true`) or redo (`undo: false`) of a
    /// completion record performs (#196). Pure, so a regression in the mapping —
    /// e.g. a redo that infers `!wasCompleted` — fails a unit test instead of
    /// reopening a reminder on device. `nil` for records that are not completions.
    func completionWrite(undo: Bool, now: Date) -> ReminderCompletionWrite? {
        switch self {
        case .completeReminder(_, let wasCompleted, let requestedCompleted, let completionDate, _, let redoCompletionDate):
            return undo ? ReminderCompletionWrite.plan(isCompleted: wasCompleted, recorded: completionDate, now: now)
                        : ReminderCompletionWrite.plan(isCompleted: requestedCompleted, recorded: redoCompletionDate, now: now)
        case .completeRecurringReminder(let before, let requestedCompleted, let redoCompletionDate):
            return undo ? ReminderCompletionWrite.plan(isCompleted: before.isCompleted, recorded: before.completionDate, now: now)
                        : ReminderCompletionWrite.plan(isCompleted: requestedCompleted, recorded: redoCompletionDate, now: now)
        default:
            return nil
        }
    }
}

enum UndoFailureDisposition: Equatable {
    case restore   // transient: keep the entry so the user can fix and retry (#191)
    case discard   // permanent: drop the entry so older operations stay reachable

    static func of(_ error: Error) -> Self {
        error is UnrecoverableUndoError ? .discard : .restore
    }
}

/// Fixed, author-controlled errors; a failed request leaves the stacks unchanged.
enum UndoHistoryError: LocalizedError, Sendable, TrustedErrorMessage {
    case busy, empty, stale
    var errorDescription: String? {
        switch self {
        case .busy: return "An undo or redo is in progress. Retry after it finishes."
        case .empty: return "No undo history record is available to discard."
        case .stale: return "The undo history changed. Read undo_history and select the current top record ID."
        }
    }
}
