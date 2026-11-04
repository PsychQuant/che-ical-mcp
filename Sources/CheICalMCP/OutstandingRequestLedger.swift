import Foundation

/// #345: the requests read from stdin that have not been answered yet. `DrainingStdioTransport`
/// waits for this to empty before it ends the receive stream on stdin EOF, so a request the
/// server already read is answered before the process exits.
///
/// Pure value type over raw JSON-RPC bytes. What counts follows the SDK (swift-sdk 0.12.0,
/// `Server.start`), which tries each message as a batch, then a response, then a request, then a
/// notification:
/// - **Batches** (a JSON array) are neither recorded nor settled. The SDK handles a batch inline
///   (`try await handleBatch`, which writes the batch reply before the next message is read), so
///   the receive loop cannot end before that reply is written (PR #409 verify round 2).
/// - **Requests**: an object with `method` and an `id` key. The id is what the SDK's `ID` decoding
///   accepts: a string; a number it decodes as `Int` (integer literals in `Int64` range, and
///   integral literals such as `2.0` or `1e2`); or `null`, which it reads as the id `""`. A number
///   with a fraction, a boolean, or an integer beyond `Int64` is rejected there and not recorded
///   here. A `notifications/cancelled` that carries an id is a request too (the SDK answers it with
///   an error), so it is recorded and cancels nothing.
/// - **Notifications** (no `id` key): a `notifications/cancelled` names a request the client no
///   longer expects a reply to. That request stops counting, but this server's handlers do not
///   check cancellation, so its reply may still be written; the cancel is kept per id so that late
///   reply settles the cancelled request, not a newer one that reuses the id (round 2). If the
///   cancelled request never replies, a newer request with that id is settled one reply late and
///   the drain's time cap ends the wait.
/// - **Replies** going out (`id` with `result` or `error`, no `method`) settle one request with
///   that id; a request the server sends to the client is ignored. Settling an id with nothing
///   outstanding is a no-op.
///
/// Counted per id (round 1): a client may reuse an id once its reply is out. Ids keep their JSON
/// type (`1` and `"1"` differ). Left to the drain's time cap: a request answered under an id this
/// ledger never recorded (the SDK answers input it cannot parse under a fresh id).
struct OutstandingRequestLedger {
    private var outstanding: [String: Int] = [:]
    /// Cancelled requests whose late reply may still come, per id.
    private var cancelledAwaitingReply: [String: Int] = [:]

    var count: Int { outstanding.values.reduce(0, +) }
    var isEmpty: Bool { outstanding.isEmpty }

    mutating func noteIncoming(_ data: Data) {
        guard let message = Self.object(in: data), let method = message["method"] as? String else { return }
        if message.keys.contains("id") {
            if let key = Self.key(message["id"]) { outstanding[key, default: 0] += 1 }
            return
        }
        if method == "notifications/cancelled",
           let params = message["params"] as? [String: Any],
           let key = Self.key(params["requestId"]), outstanding[key] != nil {
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
    private static func key(_ id: Any?) -> String? {
        switch id {
        case let string as String:
            return "s:" + string
        case is NSNull:
            return "s:"   // the SDK reads a null id as ""
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
