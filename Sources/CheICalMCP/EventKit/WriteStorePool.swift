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
/// the pool never reaches that limit.
///
/// Generic over the store type so the counting is tested without building an `EKEventStore` (#283).
final class WriteStorePool<Store: AnyObject>: @unchecked Sendable {
    static var capacity: Int { 4 }

    private let lock = NSLock()
    private var open = 0
    let make: () -> Store

    init(make: @escaping () -> Store) {
        self.make = make
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
/// store for every write of the call (a batch shares it), replaces that store after any write that
/// throws (so a failed change is not carried into the next row's commit), and releases its place
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
        let current = try currentStore()
        do {
            return try body(current)
        } catch {
            lock.lock()
            store = pool.make()   // the failed store is dropped; the place stays taken
            lock.unlock()
            throw error
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
        store = made
        return made
    }
}

/// The lease of the call running on this task. Bound to the task, not to the manager, so a request
/// that runs while another awaits (the manager is a reentrant actor) never sees another call's lease.
enum WriteStoreContext {
    @TaskLocal static var current: AnyObject?
}
