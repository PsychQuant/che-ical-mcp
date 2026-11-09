import XCTest
@testable import CheICalMCP

/// PR #507 round 1, LOW 7: a batch row the write store could not answer keeps its own code, and a
/// busy pool before any row was removed refuses the whole call.
final class WriteStoreRowFailureTests: XCTestCase {
    func testWriteStoreErrorsKeepTheirOwnRowCodes() {
        XCTAssertEqual(WriteStoreRowFailure.code(for: EventKitError.writeStoreLookupFailed(kind: "reminder")), "write_store_lookup_failed")
        XCTAssertEqual(WriteStoreRowFailure.code(for: EventKitError.writeStoreBusy), "write_store_busy")
        XCTAssertEqual(WriteStoreRowFailure.code(for: EventKitError.writeStoreReadBackFailed(kind: "reminder")), "write_store_read_back_failed")
    }

    func testOtherErrorsAreLeftToTheSanitizer() {
        XCTAssertNil(WriteStoreRowFailure.code(for: NSError(domain: "EKErrorDomain", code: 3)))
        XCTAssertNil(WriteStoreRowFailure.code(for: EventKitError.reminderNotFound(identifier: "r")))
    }

    func testABusyPoolBeforeAnyRemovalEndsTheCall() {
        XCTAssertTrue(WriteStoreRowFailure.endsTheBatch(EventKitError.writeStoreBusy, removedSoFar: 0))
        XCTAssertFalse(WriteStoreRowFailure.endsTheBatch(EventKitError.writeStoreBusy, removedSoFar: 1))
        XCTAssertFalse(WriteStoreRowFailure.endsTheBatch(EventKitError.writeStoreLookupFailed(kind: "reminder"), removedSoFar: 0))
    }
}
