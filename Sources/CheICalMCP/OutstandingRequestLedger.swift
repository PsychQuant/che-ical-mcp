import Foundation

/// #345: the requests read from stdin that have not been answered yet. `DrainingStdioTransport`
/// waits for this to empty before it ends the receive stream on stdin EOF, so a request the
/// server already read is answered before the process exits.
///
/// Pure value type over raw JSON-RPC bytes (single messages and batches):
/// - incoming: an object with `method` and a non-null `id` is outstanding; a
///   `notifications/cancelled` settles the request it names (the SDK sends no reply to a
///   cancelled request); responses coming in are not ours to wait for;
/// - outgoing: an object with `id` and `result` or `error` (and no `method`) settles that id;
///   a request the server sends to the client is ignored.
/// Ids keep their JSON type: `1` and `"1"` are different requests. Bytes that do not parse are
/// ignored (the SDK answers them with a parse error under an id nobody registered).
struct OutstandingRequestLedger {
    private var outstanding: Set<String> = []

    var count: Int { outstanding.count }
    var isEmpty: Bool { outstanding.isEmpty }

    mutating func noteIncoming(_ data: Data) {
        for message in Self.messages(in: data) {
            guard let method = message["method"] as? String else { continue }
            if method == "notifications/cancelled",
               let params = message["params"] as? [String: Any],
               let key = Self.key(params["requestId"]) {
                outstanding.remove(key)
                continue
            }
            if let key = Self.key(message["id"]) { outstanding.insert(key) }
        }
    }

    mutating func noteOutgoing(_ data: Data) {
        for message in Self.messages(in: data) where message["method"] == nil {
            guard message["result"] != nil || message["error"] != nil, let key = Self.key(message["id"]) else { continue }
            outstanding.remove(key)
        }
    }

    private static func messages(in data: Data) -> [[String: Any]] {
        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return [] }
        if let object = parsed as? [String: Any] { return [object] }
        if let array = parsed as? [Any] { return array.compactMap { $0 as? [String: Any] } }
        return []
    }

    /// A JSON-RPC id as a typed key; nil for a missing or null id.
    private static func key(_ id: Any?) -> String? {
        switch id {
        case let string as String:
            return "s:" + string
        case let number as NSNumber:
            // JSONSerialization hands booleans as NSNumber too; an id is never a boolean.
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            return "n:" + number.stringValue
        default:
            return nil
        }
    }
}
