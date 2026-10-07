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
    /// Without such alarms the error surfaces unchanged. A copy whose save failed was not
    /// written by a later save on device (#261, iCloud, 2026-10-07, probe S3): a copy into a
    /// live calendar whose `save(_:span:commit: true)` failed, because an event staged into a
    /// calendar deleted elsewhere made the commit fail, was not seen from another process after
    /// an unrelated save (which succeeded) or after a bare `commit()`, although the copy still
    /// reported unsaved changes. When the failure came from an explicit `commit()` instead (S2,
    /// a call this server does not make), the staged change stayed and the next save failed
    /// too. This covers the failure classes tried, not every possible failure. The copy gets
    /// no discard, unlike a new reminder (`NewObjectSave`): removing a recurring event without
    /// committing after its failed save made the next save fail.
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
