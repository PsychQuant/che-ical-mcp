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

    /// #253 verify round 2 (D1): saves a copy that carries `alarms`. Since #230 a copy keeps
    /// location, email and sound alarms, and whether a calendar outside iCloud accepts them is
    /// unverified. A refused copy is not retried (a retry could not undo the refused copy, and
    /// could not tell an alarm refusal from any other failure): it fails as before, and when it
    /// carries any of those alarms the error names them as a possible cause. `logFailure`
    /// writes the underlying error to stderr and returns its sanitized code for the message.
    /// Without such alarms the error surfaces unchanged. A copy whose save failed may stay
    /// pending in the shared store, where a later save can write it (#261, pre-existing).
    static func saveCopy<Value>(carrying alarms: [AlarmSnapshot], logFailure: (Error) -> String,
                                save: () throws -> Value) throws -> Value {
        do {
            return try save()
        } catch {
            let kinds = AlarmSnapshot.kindsSomeCalendarsMayRefuse(alarms)
            guard !kinds.isEmpty else { throw error }
            throw EventKitError.copyRefused(code: logFailure(error), alarmKinds: kinds)
        }
    }
}
