import Foundation

/// #459: the write stores that existing reminder and list writes commit on.
///
/// A failed commit stays pending in the store it was made on, and that store's next commit of
/// anything writes it (#274). Committing on a separate store, dropped after the call, keeps that
/// pending change out of the server's long-lived store: measured 2026-11-09 (iCloud, one process),
/// a commit that failed with EKCADErrorDomain 1010 on a separate store did not land after the
/// long-lived store saved something else, while the same failure on the long-lived store did.
///
/// At most `capacity` stores are open at once. EventKit allows 10 live stores per process (measured
/// the same day: the 11th sees no calendars at all, with no error), and the server already holds up
/// to three others. A call that would open a fifth is refused (`EventKitError.writeStoreBusy`), so
/// the pool stays under that limit as long as a dropped store is freed. Each use runs in an
/// autorelease pool and a failed store is dropped at once, not kept until a replacement is built
/// (PR #507 round 1); that the dropped store is then freed was not measured. A store that sees no
/// data (`isUsable` false, the 11th-store symptom) is refused as busy, so it is never written through.
///
/// Generic over the store type so the counting is tested without building an `EKEventStore` (#283).
final class WriteStorePool<Store: AnyObject>: @unchecked Sendable {
    static var capacity: Int { 4 }

    private let lock = NSLock()
    private var open = 0
    let make: () -> Store
    let isUsable: (Store) -> Bool

    init(make: @escaping () -> Store, isUsable: @escaping (Store) -> Bool = { _ in true }) {
        self.make = make
        self.isUsable = isUsable
    }

    var openCount: Int {
        lock.lock(); defer { lock.unlock() }
        return open
    }

    /// Takes one place, or refuses when every place is taken.
    func reserve() throws {
        lock.lock(); defer { lock.unlock() }
        guard open < Self.capacity else { throw EventKitError.writeStoreBusy }
        open += 1
    }

    func release() {
        lock.lock(); defer { lock.unlock() }
        open = max(0, open - 1)
    }
}

/// One call's write store. It takes a place in the pool only when a write first needs it, keeps one
/// store for every write of the call (a batch shares it), drops that store after any write that
/// throws (so a failed change is not carried into the next row's commit; the next write builds a
/// new one), and releases its place
/// when closed or dropped.
final class WriteStoreLease<Store: AnyObject>: @unchecked Sendable {
    private let pool: WriteStorePool<Store>
    private let lock = NSLock()
    private var store: Store?
    private var holdsPlace = false

    init(pool: WriteStorePool<Store>) {
        self.pool = pool
    }

    func use<T>(_ body: (Store) throws -> T) throws -> T {
        try autoreleasepool {
            let current = try currentStore()
            do {
                return try body(current)
            } catch {
                lock.lock()
                store = nil   // the failed store is dropped; the place stays taken
                lock.unlock()
                throw error
            }
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        store = nil
        if holdsPlace {
            holdsPlace = false
            pool.release()
        }
    }

    deinit { close() }

    private func currentStore() throws -> Store {
        lock.lock(); defer { lock.unlock() }
        if let store { return store }
        if !holdsPlace {
            try pool.reserve()
            holdsPlace = true
        }
        let made = pool.make()
        guard pool.isUsable(made) else { throw EventKitError.writeStoreBusy }
        store = made
        return made
    }
}

/// PR #507 round 1, LOW 7: what a batch row answers when the write store could not do it. These are
/// this server's own errors, so the row keeps their own code rather than the sanitizer's
/// `error_unknown`; every other error goes through the sanitizer as before (spec R3).
enum WriteStoreRowFailure {
    static func code(for error: Error) -> String? {
        switch error as? EventKitError {
        case .writeStoreBusy: return "write_store_busy"
        case .writeStoreLookupFailed: return "write_store_lookup_failed"
        case .writeStoreReadBackFailed: return "write_store_read_back_failed"
        default: return nil
        }
    }

    /// A busy pool is met at the first write (the lease takes its place then), so with nothing removed
    /// yet it refuses the whole call instead of failing every row.
    static func endsTheBatch(_ error: Error, removedSoFar: Int) -> Bool {
        guard case .writeStoreBusy = error as? EventKitError else { return false }
        return removedSoFar == 0
    }
}

/// The lease of the call running on this task. Bound to the task, not to the manager, so a request
/// that runs while another awaits (the manager is a reentrant actor) never sees another call's lease.
enum WriteStoreContext {
    @TaskLocal static var current: AnyObject?
}
