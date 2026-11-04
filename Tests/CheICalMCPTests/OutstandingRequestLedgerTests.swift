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

    /// The client does not expect a reply to a request it cancelled, so the cancel settles it. This
    /// server's handlers do not check cancellation, so a reply may still be sent; settling it then
    /// is a no-op (`testAReplyAfterACancelIsANoOp`).
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

    /// PR #409 verify round 1: entries are counted per id. The same id read twice is two
    /// requests (the SDK answers each), so it takes two replies to settle.
    func testTheSameIdReadTwiceTakesTwoReplies() {
        var ledger = OutstandingRequestLedger()
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#))
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#))
        XCTAssertEqual(ledger.count, 2)
        ledger.noteOutgoing(data(#"{"jsonrpc":"2.0","id":3,"result":{}}"#))
        XCTAssertEqual(ledger.count, 1)
        ledger.noteOutgoing(data(#"{"jsonrpc":"2.0","id":3,"result":{}}"#))
        XCTAssertTrue(ledger.isEmpty)
    }

    /// PR #409 verify round 1: an id reused after its reply was settled is a new request.
    func testAnIdReusedAfterItsReplyIsOutstandingAgain() {
        var ledger = OutstandingRequestLedger()
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#))
        ledger.noteOutgoing(data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#))
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#))
        XCTAssertEqual(ledger.count, 1)
    }

    /// PR #409 verify round 1: a numeric id that is not an integer is not recorded (the SDK's id
    /// decoding rejects it and never replies under it). `1.0` is the integer 1.
    func testANonIntegerNumericIdIsNotRecorded() {
        var ledger = OutstandingRequestLedger()
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#))
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#))
        XCTAssertTrue(ledger.isEmpty)
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":2.0,"method":"ping"}"#))
        ledger.noteOutgoing(data(#"{"jsonrpc":"2.0","id":2,"result":{}}"#))
        XCTAssertTrue(ledger.isEmpty)
    }

    /// PR #409 verify round 1: a reply sent after the request was cancelled (this server's
    /// handlers do not check cancellation, so it can still come) settles nothing and does not
    /// underflow: a later request with that id is still counted.
    func testAReplyAfterACancelIsANoOp() {
        var ledger = OutstandingRequestLedger()
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call"}"#))
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#))
        ledger.noteOutgoing(data(#"{"jsonrpc":"2.0","id":7,"result":{}}"#))
        XCTAssertTrue(ledger.isEmpty)
        ledger.noteIncoming(data(#"{"jsonrpc":"2.0","id":7,"method":"tools/call"}"#))
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
