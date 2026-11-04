import Foundation

/// #345: the requests read from stdin that have not been answered yet. `DrainingStdioTransport`
/// waits for this to empty before it ends the receive stream on stdin EOF, so a request the
/// server already read is answered before the process exits. "Read" means a newline-terminated
/// line: swift-sdk 0.12.0's `StdioTransport` ends its stream at EOF without yielding a last line
/// that has no trailing newline, so such a request never reaches the server (SDK framing, not
/// handled here).
///
/// Pure value type over raw JSON-RPC bytes. What counts follows the SDK (0.12.0, `Server.start`),
/// which tries each message as a batch, then a response, then a request, then a notification, and
/// decodes each only with `"jsonrpc": "2.0"`:
/// - **Batches** (a JSON array) are neither recorded nor settled. The SDK handles a batch inline
///   (`try await handleBatch`, which writes the batch reply before the next message is read), so
///   the receive loop cannot end before that reply is written (PR #409 verify round 2).
/// - **Responses** coming in (an object with `result` or `error`) get no reply and are skipped.
/// - **Requests**: an object with `method` and an `id` key. The id is what the SDK's `ID` decoding
///   accepts: a string; a number it decodes as `Int` (integer literals in `Int64` range, and
///   integral literals such as `2.0` or `1e2`); or `null`, which it reads as the id `""`. A number
///   with a fraction, a boolean, or an integer beyond `Int64` is rejected there and not recorded
///   here. A `notifications/cancelled` that carries an id is a request too (the SDK answers it with
///   an error), so it is recorded and cancels nothing.
/// - **Notifications** (no `id` key): a `notifications/cancelled` names a request the client no
///   longer expects a reply to; a null `requestId` names none. That request stops counting. The
///   SDK drops its reply only when the cancel arrives before the handler starts; this server's
///   handlers do not check cancellation, so otherwise the reply is still written. The cancel is
///   kept per id so that late reply settles the cancelled request, not a newer one with the same
///   id; when the SDK did drop the reply, that kept cancel is never cleared, and a newer request
///   with the same id is settled one reply late, so the drain waits for its time cap.
/// - **Replies** going out (`id` with `result` or `error`, no `method`) settle one request with
///   that id; a request the server sends to the client is ignored. Settling an id with nothing
///   outstanding is a no-op.
///
/// Counted per id (round 1): MCP forbids reusing an id or a null id, but a non-conforming client
/// may reuse one once its reply is out. Ids keep their JSON type (`1` and `"1"` differ).
///
/// Known limits, all needing a client outside the MCP spec; the worst case is a wait until the
/// drain's time cap, except the last, which can end the drain one reply early: a cancel inside a
/// batch is not seen; an id below `Int64.min`, or a `Double` / decimal literal whose rounding
/// differs from the SDK's, is keyed differently from its reply; a malformed message the SDK answers
/// under an id it extracts itself can settle (or fail to settle) a recorded request with that id.
struct OutstandingRequestLedger {
    private var outstanding: [String: Int] = [:]
    /// Cancelled requests whose late reply may still come, per id.
    private var cancelledAwaitingReply: [String: Int] = [:]

    var count: Int { outstanding.values.reduce(0, +) }
    var isEmpty: Bool { outstanding.isEmpty }

    mutating func noteIncoming(_ data: Data) {
        // Round 3: the SDK decodes requests, notifications and responses only with
        // `"jsonrpc": "2.0"`; and an object with `result` or `error` is tried as a response first,
        // which gets no reply.
        guard let message = Self.object(in: data), message["jsonrpc"] as? String == "2.0",
              let method = message["method"] as? String,
              message["result"] == nil, message["error"] == nil else { return }
        if message.keys.contains("id") {
            if let key = Self.key(message["id"]) { outstanding[key, default: 0] += 1 }
            return
        }
        if method == "notifications/cancelled",
           let params = message["params"] as? [String: Any],
           let key = Self.key(params["requestId"], nullIsEmptyString: false), outstanding[key] != nil {
            Self.decrement(&outstanding, key)
            cancelledAwaitingReply[key, default: 0] += 1
        }
    }

    mutating func noteOutgoing(_ data: Data) {
        guard let message = Self.object(in: data), message["method"] == nil,
              message["result"] != nil || message["error"] != nil,
              let key = Self.key(message["id"]) else { return }
        if cancelledAwaitingReply[key] != nil {
            Self.decrement(&cancelledAwaitingReply, key)
        } else {
            Self.decrement(&outstanding, key)
        }
    }

    private static func decrement(_ counts: inout [String: Int], _ key: String) {
        guard let n = counts[key] else { return }
        counts[key] = n > 1 ? n - 1 : nil
    }

    /// The single JSON object `data` holds; nil for a batch (array) or unparseable input.
    private static func object(in data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any]
    }

    /// A JSON-RPC id as the SDK decodes it, as a typed key; nil where the SDK rejects it.
    /// `nullIsEmptyString`: a request's null id is the id `""` (the SDK's `ID` decoding); a
    /// cancel's null `requestId` names no request (the SDK decodes it to nil), round 3.
    private static func key(_ id: Any?, nullIsEmptyString: Bool = true) -> String? {
        switch id {
        case let string as String:
            return "s:" + string
        case is NSNull:
            return nullIsEmptyString ? "s:" : nil
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            switch String(cString: number.objCType) {
            case "d", "f":
                // An integral literal such as 2.0 or 1e2: the SDK's Int decoding takes it.
                let value = number.doubleValue
                guard value.isFinite, value.rounded() == value,
                      value >= -9_223_372_036_854_775_808.0, value < 9_223_372_036_854_775_808.0 else { return nil }
                return "n:" + String(Int64(value))
            case "Q":
                // Unsigned: only values that fit Int64 decode as Int.
                return number.uint64Value <= UInt64(Int64.max) ? "n:" + String(number.uint64Value) : nil
            default:
                // Integer literals: read exactly, without a Double round trip.
                return "n:" + String(number.int64Value)
            }
        default:
            return nil
        }
    }
}
