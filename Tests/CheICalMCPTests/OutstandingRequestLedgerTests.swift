import Foundation
import XCTest
@testable import CheICalMCP

/// #345: the bookkeeping behind `DrainingStdioTransport`. A request (an object with `method` and a
/// non-null `id`) read from stdin is outstanding until a response (`result` or `error`) with the
/// same `id` is sent, or a `notifications/cancelled` names it (the SDK then sends no reply).
final class OutstandingRequestLedgerTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testARequestIsOutstandingUntilItsResultIsSent() {
        var ledger = OutstandingRequestLedger()
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#))
        XCTAssertEqual(ledger.count, 1)
        ledger.noteOutgoing(data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#))
        XCTAssertTrue(ledger.isEmpty)
    }

    func testAnErrorResponseSettlesItToo() {
        var ledger = OutstandingRequestLedger()
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":"abc","method":"tools/call"}"#))
        ledger.noteOutgoing(data(#"{"jsonrpc":"2.0","id":"abc","error":{"code":-32601,"message":"x"}}"#))
        XCTAssertTrue(ledger.isEmpty)
    }

    func testANotificationIsNeverOutstanding() {
        var ledger = OutstandingRequestLedger()
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#))
        XCTAssertTrue(ledger.isEmpty)
    }

    func testAStringIdAndANumberIdWithTheSameTextAreDifferentRequests() {
        var ledger = OutstandingRequestLedger()
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#))
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":"1","method":"ping"}"#))
        XCTAssertEqual(ledger.count, 2)
        ledger.noteOutgoing(data(#"{"jsonrpc":"2.0","id":"1","result":{}}"#))
        XCTAssertEqual(ledger.count, 1)
        ledger.noteOutgoing(data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#))
        XCTAssertTrue(ledger.isEmpty)
    }

    func testABatchIsCountedPerMemberAndSettledPerReply() {
        var ledger = OutstandingRequestLedger()
        ledger.noteIncoming(data(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"},{"jsonrpc":"2.0","id":2,"method":"tools/list"}]"#))
        XCTAssertEqual(ledger.count, 2)
        ledger.noteOutgoing(data(#"[{"jsonrpc":"2.0","id":2,"result":{}},{"jsonrpc":"2.0","id":1,"result":{}}]"#))
        XCTAssertTrue(ledger.isEmpty)
    }

    /// A request the client cancels gets no reply from the SDK, so the cancel settles it.
    func testACancelledNotificationSettlesTheRequestItNames() {
        var ledger = OutstandingRequestLedger()
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call"}"#))
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#))
        XCTAssertTrue(ledger.isEmpty)
    }

    /// A request the server sends to the client (an object with `method` and `id` going out) is
    /// not one of ours to wait for, and a response coming in does not settle anything.
    func testOutgoingRequestsAndIncomingResponsesAreIgnored() {
        var ledger = OutstandingRequestLedger()
        ledger.noteOutgoing(data(#"{"jsonrpc":"2.0","id":9,"method":"roots/list"}"#))
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":9,"result":{}}"#))
        XCTAssertTrue(ledger.isEmpty)
    }

    /// The same id read twice is one outstanding entry: the reply settles it once.
    func testADuplicateIdIsOneEntry() {
        var ledger = OutstandingRequestLedger()
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#))
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#))
        XCTAssertEqual(ledger.count, 1)
    }

    /// Bytes that are not JSON (the SDK answers them with a parse error under a fresh id) are
    /// not counted, and a reply with an unknown id settles nothing.
    func testUnparseableInputAndUnknownRepliesChangeNothing() {
        var ledger = OutstandingRequestLedger()
        ledger.noteIncoming(data("not json"))
        ledger.noteOutgoing(data(#"{"jsonrpc":"2.0","id":"random","error":{"code":-32700,"message":"Parse error"}}"#))
        XCTAssertTrue(ledger.isEmpty)
    }
}
