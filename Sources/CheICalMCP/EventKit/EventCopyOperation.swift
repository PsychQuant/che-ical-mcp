/// Synchronous coordination keeps EventKit closures on the calling actor.
enum EventCopyOperation {
    struct Outcome<Value> {
        let value: Value
        let undo: UndoOperation?
    }

    static func execute<Value>(source: EventSnapshot?, saveCopy: () throws -> Value,
                               removeSource: () throws -> Void) throws -> Outcome<Value> {
        let value = try saveCopy()
        if let source {
            try removeSource()
            return Outcome(value: value, undo: .deleteEvent(snapshot: source))
        }
        return Outcome(value: value, undo: nil)
    }
}
