@testable import CheICalMCP

/// #600: how a test builds `CheICalMCPServer`. It takes the init's parameters, in the init's order,
/// and gives every one the test leaves out a double instead of `EventKitManager.shared`: `filler`, a
/// `DispatchProbe` whose every method records its name and throws, and an undo history of the
/// server's own instead of `CalendarUndoManager.shared`. Under XCTest the live manager and the
/// shared history stop the process (`LiveStoreGuard`), so a server built any other way with a
/// default left in fails at once.
enum TestServer {
    static func make(reminderCleanupSource: (any EventKitManaging)? = nil,
                     reminderReadSource: (any ReminderReadSource)? = nil,
                     eventCopySource: (any EventCopySource)? = nil,
                     eventWriteSource: (any EventWriteSource)? = nil,
                     eventDeletionSource: (any EventDeletionSource)? = nil,
                     calendarDeletionSource: (any CalendarDeletionSource)? = nil,
                     calendarWriteSource: (any CalendarWriteSource)? = nil,
                     eventBatchDeletionSource: (any EventBatchDeletionSource)? = nil,
                     duplicateSearchSource: (any DuplicateSearchSource)? = nil,
                     eventRangeReadSource: (any EventRangeReadSource)? = nil,
                     calendarListSource: (any CalendarListSource)? = nil,
                     reminderWriteSource: (any ReminderWriteSource)? = nil,
                     undoManager: CalendarUndoManager? = nil,
                     reminderCompletionSource: (any ReminderCompletionSource)? = nil,
                     undoExecutionSource: (any UndoExecutionSource)? = nil,
                     filler: DispatchProbe = DispatchProbe()) async throws -> CheICalMCPServer {
        try await CheICalMCPServer(
            reminderCleanupSource: reminderCleanupSource ?? filler,
            reminderReadSource: reminderReadSource ?? filler,
            eventCopySource: eventCopySource ?? filler,
            eventWriteSource: eventWriteSource ?? filler,
            eventDeletionSource: eventDeletionSource ?? filler,
            calendarDeletionSource: calendarDeletionSource ?? filler,
            calendarWriteSource: calendarWriteSource ?? filler,
            eventBatchDeletionSource: eventBatchDeletionSource ?? filler,
            duplicateSearchSource: duplicateSearchSource ?? filler,
            eventRangeReadSource: eventRangeReadSource ?? filler,
            calendarListSource: calendarListSource ?? filler,
            reminderWriteSource: reminderWriteSource ?? filler,
            undoManager: undoManager ?? CalendarUndoManager(),
            reminderCompletionSource: reminderCompletionSource ?? filler,
            undoExecutionSource: undoExecutionSource ?? filler)
    }
}
