import Foundation

/// #269 verify (PR #389 round 1, finding 2): when an event undo judges the calendar it restores into
/// missing. A view that only looks empty (stale after another client's change, or before access was
/// checked) must not produce the missing-calendar refusal, whose way on is to discard the undo. So,
/// in the batch pre-check's order (`UndoRestoreDestination.verify`): read, and on a miss mark the
/// view stale and read once more before the refusal stands. A read that fails (Calendar access) is
/// that error, never a missing calendar. The refresh is requested, not awaited (EventKit syncs in
/// the background), so the second read may still see the old view; the refusal's retry advice
/// covers that. Closure seam, so the order is unit-tested without EventKit.
enum EventRestoreCalendar {
    /// `match` picks the calendar from a read, or throws the refusal.
    static func resolve<C>(read: () async throws -> [C], invalidate: () -> Void,
                           match: ([C]) throws -> C) async throws -> C {
        let first = try await read()
        if let found = try? match(first) { return found }
        invalidate()
        return try match(try await read())
    }

    /// The synchronous form, for the stand-in lookup inside the target check: nil after two misses.
    static func lookup<T>(read: () -> T?, invalidate: () -> Void) -> T? {
        if let found = read() { return found }
        invalidate()
        return read()
    }
}
