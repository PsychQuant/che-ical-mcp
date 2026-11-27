import EventKit
import Foundation
@testable import CheICalMCP

/// #575: a test double for every store source `CheICalMCPServer` takes. A server built with it reaches
/// no live Calendar or Reminders store through its sources; the one exception is `delete_reminder`
/// given a `reminder_id`, which calls the live manager directly (`eventKitManager.deleteReminder`),
/// so a server built with this double must not be sent that (no test line has the literal dispatch:
/// `DispatchRoundTripTests.testTheOnlyLiteralDeleteReminderDispatchLineInTheTestsIsTheEmptyOne`, a text
/// check that misses other spellings, #600; since #600 that call reaches `EventKitManager.shared`, which
/// stops the test process under XCTest, `LiveStoreGuard`). Every method records
/// its name and throws `Reached`: a handler that gets this far proves the dispatch reached it, and
/// nothing is read or written.
///
/// When the server gains a source protocol, add a conformance here and pass it in `server()`; a
/// source left at its default reaches `EventKitManager.shared` again. A default written
/// `label: any Protocol = EventKitManager.shared` and not passed here fails
/// `DispatchRoundTripTests.testTheProbeServerReplacesEveryInitParameterDefaultedToEventKitManagerShared`;
/// a default spelled another way does not. Since #600 a source left at `EventKitManager.shared`
/// stops the test process when the server is built (`LiveStoreGuard`), whatever its spelling.
actor DispatchProbe: EventKitManaging, ReminderReadSource, EventCopySource, EventWriteSource, EventDeletionSource,
    CalendarDeletionSource, CalendarWriteSource, EventBatchDeletionSource, DuplicateSearchSource,
    EventRangeReadSource, CalendarListSource, ReminderWriteSource, ReminderCompletionSource, UndoExecutionSource {

    struct Reached: Error, Equatable { let method: String }

    private(set) var calls: [String] = []

    private func reach(_ method: String) throws -> Never {
        calls.append(method)
        throw Reached(method: method)
    }

    /// A server whose every source is `probe`, with an undo history of its own.
    static func server(_ probe: DispatchProbe) async throws -> CheICalMCPServer {
        try await CheICalMCPServer(
            reminderCleanupSource: probe, reminderReadSource: probe, eventCopySource: probe, eventWriteSource: probe,
            eventDeletionSource: probe, calendarDeletionSource: probe, calendarWriteSource: probe,
            eventBatchDeletionSource: probe, duplicateSearchSource: probe, eventRangeReadSource: probe,
            calendarListSource: probe, reminderWriteSource: probe, undoManager: CalendarUndoManager(),
            reminderCompletionSource: probe, undoExecutionSource: probe)
    }

    // EventKitManaging
    func listCompletedReminderIdentifiers(calendarName: String?, calendarSource: String?) async throws -> [String] {
        try reach("listCompletedReminderIdentifiers")
    }
    func deleteRemindersBatch(identifiers: [String], onlyCompleted: Bool) async throws -> BatchDeleteResult {
        try reach("deleteRemindersBatch")
    }

    // ReminderReadSource
    func listReminderPage(completed: Bool?, calendarName: String?, calendarSource: String?, query: ReminderPageQuery) async throws -> ReminderPage {
        try reach("listReminderPage")
    }
    func searchReminderPage(keywords: [String], matchMode: String, calendarName: String?, calendarSource: String?, completed: Bool?,
                            query: ReminderPageQuery) async throws -> ReminderPage {
        try reach("searchReminderPage")
    }
    func listReminderSnapshots(completed: Bool?, calendarName: String?, calendarSource: String?) async throws -> [ReminderReadSnapshot] {
        try reach("listReminderSnapshots")
    }
    func searchReminderSnapshots(keywords: [String], matchMode: String, calendarName: String?, calendarSource: String?,
                                 completed: Bool?) async throws -> [ReminderReadSnapshot] {
        try reach("searchReminderSnapshots")
    }

    // EventCopySource
    func copyEventValue(identifier: String, toCalendarName: String, toCalendarSource: String?, deleteOriginal: Bool) async throws -> EventCopyValue {
        try reach("copyEventValue")
    }
    func moveEventValue(identifier: String, occurrenceDate: Date?, span: EventMovePolicy.Span,
                        toCalendarName: String, toCalendarSource: String?) async throws -> EventMoveValue {
        try reach("moveEventValue")
    }
    func eventTimeZone(identifier: String) async throws -> TimeZone? { try reach("eventTimeZone") }

    // EventWriteSource and EventDeletionSource
    func updateEventValue(_ request: EventUpdateRequest) async throws -> EventWriteValue { try reach("updateEventValue") }
    func createEventValue(_ request: EventCreateRequest) async throws -> EventCreateValue { try reach("createEventValue") }
    func similarEventValues(title: String, calendarIdentifier: String, excluding: Set<String>, limit: Int) async throws -> [SimilarEventValue] {
        try reach("similarEventValues")
    }
    func occurrenceDateTimeZone(identifier: String) async throws -> TimeZone? { try reach("occurrenceDateTimeZone") }
    func deleteEvent(identifier: String, span: EKSpan, occurrenceDate: Date?) async throws -> RulesAloneOnUndo? { try reach("deleteEvent") }
    func deleteEventSeries(identifier: String) async throws -> SeriesDeleteRoute { try reach("deleteEventSeries") }

    // CalendarDeletionSource and CalendarWriteSource
    func deleteCalendar(identifier: String, requireEmpty: Bool) async throws -> CalendarEmptiness.Checked? { try reach("deleteCalendar") }
    func writeNewCalendar(title: String, entityType: EKEntityType, color: String?) async throws -> CalendarWriteValue {
        try reach("writeNewCalendar")
    }
    func writeCalendarUpdate(identifier: String, title: String?, color: String?) async throws -> CalendarWriteValue {
        try reach("writeCalendarUpdate")
    }

    // EventBatchDeletionSource
    func listEventsForDeletion(startDate: Date, endDate: Date, calendarName: String?,
                               calendarSource: String?) async throws -> [BatchDeletionListedEvent] {
        try reach("listEventsForDeletion")
    }
    func deleteEventsBatch(items: [(identifier: String, occurrenceDate: Date?)], span: EKSpan,
                           slots: [Date?]?) async throws -> BatchDeleteResult {
        try reach("deleteEventsBatch")
    }
    func deleteEventSeriesBatch(identifiers: [String]) async throws -> BatchDeleteResult { try reach("deleteEventSeriesBatch") }
    func previewEventDeletion(identifier: String, span: EKSpan, spanAll: Bool, namedInTheCall: Set<String>,
                              goneInTheCall: Set<String>, forecast: BatchDeletionForecastContext?) async throws -> BatchDeletionPreviewRow {
        try reach("previewEventDeletion")
    }

    // DuplicateSearchSource
    func findDuplicateEvents(calendarNames: [String]?, startDate: Date, endDate: Date,
                             toleranceMinutes: Int) async throws -> DuplicateSearchValue {
        try reach("findDuplicateEvents")
    }

    // EventRangeReadSource and CalendarListSource
    func listEventValues<Info: Sendable>(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                                         pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info> {
        try reach("listEventValues")
    }
    func searchEventValues<Info: Sendable>(keywords: [String], matchMode: String, startDate: Date?, endDate: Date?,
                                           calendarName: String?, calendarSource: String?,
                                           pick: EventRowPick<Info>) async throws -> EventRowsPicked<Info> {
        try reach("searchEventValues")
    }
    func checkConflictValues(startDate: Date, endDate: Date, calendarName: String?, calendarSource: String?,
                             excludeEventId: String?) async throws -> [EventReadValue] {
        try reach("checkConflictValues")
    }
    func listCalendarValues(for entityType: EKEntityType?) async throws -> [CalendarReadValue] { try reach("listCalendarValues") }

    // ReminderWriteSource and ReminderCompletionSource
    func createReminder(_ request: ReminderCreateRequest) async throws -> EventKitManager.CreateReminderResult { try reach("createReminder") }
    func updateReminder(_ request: ReminderUpdateRequest) async throws -> ReminderUpdateResult { try reach("updateReminder") }
    func getReminder(identifier: String) async throws -> ReminderWriteSnapshot { try reach("getReminder") }
    func completeReminder(identifier: String, completed: Bool) async throws -> ReminderCompletionResult { try reach("completeReminder") }

    // UndoExecutionSource
    func executeUndo(_ operation: UndoOperation) async throws -> String { try reach("executeUndo") }
    func executeUndo(_ operation: UndoOperation, restoreAvailable: Bool) async throws -> String { try reach("executeUndo(restoreAvailable:)") }
    func executeUndoKeepingLaterEdits(_ operation: UndoOperation) async throws -> String { try reach("executeUndoKeepingLaterEdits") }
    func executeRedo(_ operation: UndoOperation) async throws -> String { try reach("executeRedo") }
}
