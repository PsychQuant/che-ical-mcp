import Foundation

/// #236: the `undo` / `redo` handlers' EventKit dependency, narrowed to the two calls they make,
/// so a handler test can drive a post-state refusal (record kept, message verbatim) without
/// EventKit. Production uses `EventKitManager.shared`.
protocol UndoExecutionSource: Sendable {
    func executeUndo(_ operation: UndoOperation) async throws -> String
    /// #287: `restoreAvailable` asks a refused batch to restore the members whose calendar or list
    /// is in place and keep the others (`UndoBatchKeptUnavailable`).
    func executeUndo(_ operation: UndoOperation, restoreAvailable: Bool) async throws -> String
    func executeRedo(_ operation: UndoOperation) async throws -> String
}

extension UndoExecutionSource {
    /// A source that has no partial restore (the test doubles before #287) runs the plain undo.
    func executeUndo(_ operation: UndoOperation, restoreAvailable: Bool) async throws -> String {
        try await executeUndo(operation)
    }
}

extension EventKitManager: UndoExecutionSource {}
