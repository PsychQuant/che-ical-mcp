import Foundation

/// #236: the `undo` / `redo` handlers' EventKit dependency, narrowed to the two calls they make,
/// so a handler test can drive a post-state refusal (record kept, message verbatim) without
/// EventKit. Production uses `EventKitManager.shared`.
protocol UndoExecutionSource: Sendable {
    func executeUndo(_ operation: UndoOperation) async throws -> String
    func executeRedo(_ operation: UndoOperation) async throws -> String
}

extension EventKitManager: UndoExecutionSource {}
