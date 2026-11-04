import Foundation

/// #345: the requests read from stdin that have not been answered yet. `DrainingStdioTransport`
/// waits for this to empty before it ends the receive stream on stdin EOF, so a request the
/// server already read is answered before the process exits.
///
/// Pure value type over raw JSON-RPC bytes (single messages and batches), counted per id
/// (PR #409 verify round 1: a client may reuse an id once its reply is out, so one id can stand
/// for several requests over time; each is settled by one reply):
/// - incoming: an object with `method` and an id that is a string or an integer is outstanding
///   (a numeric id with a fraction, or a boolean, is not: the SDK's id decoding rejects it and
///   never replies under it); a `notifications/cancelled` settles one request it names, since the
///   client does not expect a reply to a cancelled request; responses coming in are not ours;
/// - outgoing: an object with `id` and `result` or `error` (and no `method`) settles one request
///   with that id; a request the server sends to the client is ignored.
/// Settling an id that has nothing outstanding is a no-op: this server's handlers do not check
/// cancellation, so a reply can still follow a cancel. Ids keep their JSON type: `1` and `"1"` are
/// different requests. Bytes that do not parse are ignored.
///
/// Left to the drain's time cap, not settled here: a request answered under an id this ledger
/// never recorded. The SDK does that for a batch it cannot decode (one invalid member makes it
/// answer the whole batch with one error under a fresh id), and for input it cannot parse.
struct OutstandingRequestLedger {
    private var outstanding: [String: Int] = [:]

    var count: Int { outstanding.values.reduce(0, +) }
    var isEmpty: Bool { outstanding.isEmpty }

    mutating func noteIncoming(_ data: Data) {
        for message in Self.messages(in: data) {
            guard let method = message["method"] as? String else { continue }
            if method == "notifications/cancelled",
               let params = message["params"] as? [String: Any],
               let key = Self.key(params["requestId"]) {
                settle(key)
                continue
            }
            if let key = Self.key(message["id"]) { outstanding[key, default: 0] += 1 }
        }
    }

    mutating func noteOutgoing(_ data: Data) {
        for key in Self.repliedKeys(in: data) { settle(key) }
    }

    /// The ids `data` answers, one per reply in it.
    static func repliedKeys(in data: Data) -> [String] {
        messages(in: data).compactMap { message in
            guard message["method"] == nil, message["result"] != nil || message["error"] != nil else { return nil }
            return key(message["id"])
        }
    }

    private mutating func settle(_ key: String) {
        guard let n = outstanding[key] else { return }
        outstanding[key] = n > 1 ? n - 1 : nil
    }

    private static func messages(in data: Data) -> [[String: Any]] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
        if let object = parsed as? [String: Any] { return [object] }
        if let array = parsed as? [Any] { return array.compactMap { $0 as? [String: Any] } }
        return []
    }

    /// A JSON-RPC id as a typed key; nil for a missing or null id, a boolean, or a number with a
    /// fraction.
    private static func key(_ id: Any?) -> String? {
        switch id {
        case let string as String:
            return "s:" + string
        case let number as NSNumber:
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value.rounded() == value, abs(value) < 9.0e15 else { return nil }
            return "n:" + String(Int64(value))
        default:
            return nil
        }
    }
}
