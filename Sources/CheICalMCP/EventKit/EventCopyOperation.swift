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

    /// #253 verify #2: `save` builds a copy with the given alarms and saves it. Since #230 a
    /// copy carries location, email and sound alarms, which a calendar outside iCloud may
    /// refuse; before, every copied alarm was time-only and such a copy succeeded. So when
    /// the first save fails and the alarms carry any of those, the copy is saved once more
    /// with time-only alarms and the dropped kinds are returned. Without them, or when the
    /// retry fails too, the error surfaces as before. `onRetry` sees the first error.
    static func saveCopy<Value>(alarms: [AlarmSnapshot], onRetry: (Error) -> Void = { _ in },
                                save: ([AlarmSnapshot]) throws -> Value) throws -> (value: Value, notCarriedOver: [String]) {
        do {
            return (try save(alarms), [])
        } catch {
            let dropped = AlarmSnapshot.kindsDroppedByTimeOnly(alarms)
            guard !dropped.isEmpty else { throw error }
            onRetry(error)
            return (try save(alarms.map(\.timeOnly)), dropped)
        }
    }
}
