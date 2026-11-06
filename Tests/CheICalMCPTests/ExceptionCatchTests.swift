import CheICalMCPObjC
import XCTest

/// #288: `CheICalCatchingException`, the only place the server catches an Objective-C exception.
final class ExceptionCatchTests: XCTestCase {
    func testAResultComesBackWithNoExceptionName() {
        var name: NSString?
        let result = CheICalCatchingException({ "value" as NSString }, &name)
        XCTAssertEqual(result as? String, "value")
        XCTAssertNil(name)
    }

    func testANilResultIsNotAnException() {
        var name: NSString?
        XCTAssertNil(CheICalCatchingException({ nil }, &name))
        XCTAssertNil(name)
    }

    func testARaiseGivesNilAndTheName() {
        var name: NSString?
        let result = CheICalCatchingException({
            NSException(name: .undefinedKeyException, reason: "not for the caller", userInfo: nil).raise()
            return "unreached" as NSString
        }, &name)
        XCTAssertNil(result)
        XCTAssertEqual(name as String?, NSExceptionName.undefinedKeyException.rawValue)
    }

    func testTheNameIsOptional() {
        XCTAssertNil(CheICalCatchingException({
            NSException(name: .genericException, reason: nil, userInfo: nil).raise()
            return nil
        }, nil))
    }
}
