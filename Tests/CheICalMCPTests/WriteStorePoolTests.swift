import XCTest
@testable import CheICalMCP

/// #459: the pool of write stores for existing reminder and list writes. Pure: a fake store type
/// stands in for `EKEventStore`, so no store is built (#283).
final class WriteStorePoolTests: XCTestCase {
    final class FakeStore {
        let serial: Int
        init(serial: Int) { self.serial = serial }
    }

    private func makePool() -> (WriteStorePool<FakeStore>, () -> Int) {
        var made = 0
        let pool = WriteStorePool<FakeStore>(make: { made += 1; return FakeStore(serial: made) })
        return (pool, { made })
    }

    func testTheCapIsFour() {
        XCTAssertEqual(WriteStorePool<FakeStore>.capacity, 4)
    }

    func testALeaseOpensNoStoreUntilItIsUsed() throws {
        let (pool, made) = makePool()
        let lease = WriteStoreLease(pool: pool)
        XCTAssertEqual(made(), 0)
        XCTAssertEqual(pool.openCount, 0)
        _ = try lease.use { $0.serial }
        XCTAssertEqual(made(), 1)
        XCTAssertEqual(pool.openCount, 1)
        lease.close()
        XCTAssertEqual(pool.openCount, 0)
    }

    func testOneLeaseKeepsOneStoreAcrossWrites() throws {
        let (pool, made) = makePool()
        let lease = WriteStoreLease(pool: pool)
        let first = try lease.use { $0.serial }
        let second = try lease.use { $0.serial }
        XCTAssertEqual(first, second)
        XCTAssertEqual(made(), 1)
        XCTAssertEqual(pool.openCount, 1)
        lease.close()
    }

    func testAFailedWriteReplacesTheStoreWithoutTakingASecondPlace() throws {
        struct Boom: Error {}
        let (pool, made) = makePool()
        let lease = WriteStoreLease(pool: pool)
        let before = try lease.use { $0.serial }
        XCTAssertThrowsError(try lease.use { _ in throw Boom() })
        let after = try lease.use { $0.serial }
        XCTAssertNotEqual(before, after, "the store a failed write used is not used again")
        XCTAssertEqual(made(), 2)
        XCTAssertEqual(pool.openCount, 1)
        lease.close()
        XCTAssertEqual(pool.openCount, 0)
    }

    func testAFifthStoreIsRefusedAndNoneIsOpened() throws {
        let (pool, made) = makePool()
        let leases = (0..<4).map { _ in WriteStoreLease(pool: pool) }
        for lease in leases { _ = try lease.use { $0.serial } }
        XCTAssertEqual(pool.openCount, 4)
        let fifth = WriteStoreLease(pool: pool)
        XCTAssertThrowsError(try fifth.use { $0.serial }) { error in
            guard case .writeStoreBusy = error as? EventKitError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(made(), 4, "no fifth store was made")
        leases[0].close()
        XCTAssertNoThrow(try fifth.use { $0.serial }, "a released place can be taken")
        for lease in leases.dropFirst() { lease.close() }
        fifth.close()
        XCTAssertEqual(pool.openCount, 0)
    }

    func testClosingTwiceReleasesOnce() throws {
        let (pool, _) = makePool()
        let a = WriteStoreLease(pool: pool)
        let b = WriteStoreLease(pool: pool)
        _ = try a.use { $0.serial }
        _ = try b.use { $0.serial }
        a.close(); a.close()
        XCTAssertEqual(pool.openCount, 1)
        b.close()
    }

    func testALeaseThatIsDroppedReleasesItsPlace() throws {
        let (pool, _) = makePool()
        do {
            let lease = WriteStoreLease(pool: pool)
            _ = try lease.use { $0.serial }
            XCTAssertEqual(pool.openCount, 1)
        }
        XCTAssertEqual(pool.openCount, 0)
    }

    func testTheTaskLocalLeaseIsOnlyVisibleInsideItsScope() async throws {
        let (pool, _) = makePool()
        XCTAssertNil(WriteStoreContext.current)
        let lease = WriteStoreLease(pool: pool)
        await WriteStoreContext.$current.withValue(lease) {
            XCTAssertTrue(WriteStoreContext.current === lease)
            let other = Task.detached { WriteStoreContext.current == nil }
            let unseen = await other.value
            XCTAssertTrue(unseen, "a detached task, like another request, does not see the lease")
        }
        XCTAssertNil(WriteStoreContext.current)
        lease.close()
    }
}
