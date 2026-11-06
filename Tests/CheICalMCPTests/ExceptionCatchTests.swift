import CheICalMCPObjC
import CheICalMCPObjCTestSupport
import XCTest

/// #288: `CheICalEventWithIdentifier`, the only place the server catches an Objective-C exception.
/// The raise comes from Objective-C, so no Swift frame is unwound, here or in production.
final class ExceptionCatchTests: XCTestCase {
    func testAQuietLookupGivesNilAndNoName() {
        var name: NSString?
        XCTAssertNil(CheICalEventWithIdentifier(CheICalRaisingEventStore(raising: nil), "id", &name))
        XCTAssertNil(name)
    }

    func testARaiseGivesNilAndItsName() {
        for raised in [NSExceptionName.undefinedKeyException, .genericException] {
            var name: NSString?
            XCTAssertNil(CheICalEventWithIdentifier(CheICalRaisingEventStore(raising: raised), "id", &name))
            XCTAssertEqual(name as String?, raised.rawValue)
        }
    }

    /// A non-nil name is how the caller knows it raised, so an exception with none still sets one.
    func testARaiseWithNoNameStillSetsTheName() {
        var name: NSString?
        XCTAssertNil(CheICalEventWithIdentifier(CheICalRaisingEventStore(raisingWithoutAName: ()), "id", &name))
        XCTAssertEqual(name as String?, "")
    }
}
