import MCP

/// #448: the arguments of a tool call, checked against the tool's schema before the handler runs.
/// The MCP SDK does not validate arguments, and a handler reads the keys it knows, so a misspelled
/// key and a value of the wrong type were dropped with no message: a misspelled `timezone` moved an
/// event, a misspelled `due_date` made a reminder with no date. A present value of the wrong type
/// must throw (#184), and so must a key the tool does not read.
enum ToolArgumentCheck {
    /// Per-tool keys the handler refuses with a message of its own, which says more than this check
    /// can: `rejectMisplacedRecurrenceKeys` and `handleFindDuplicateEvents`.
    static let refusedByTheHandler: [String: Set<String>] = {
        let beside = Set(RecurrenceRuleInput.inputKeys(allowsExclusions: true) + RecurrenceRuleInput.readKeys)
        let rule = ["create_event", "update_event", "create_reminder", "update_reminder"]
        var keys = Dictionary(uniqueKeysWithValues: rule.map { ($0, beside) })
        keys["find_duplicate_events"] = ["calendar_name", "calendar_source", "calendars"]
        return keys
    }()

    private static let schemas: [String: Value] = Dictionary(
        uniqueKeysWithValues: CheICalMCPServer.defineTools().map { ($0.name, $0.inputSchema) })

    /// Refuses a top-level key the tool does not read, or a value of the wrong type. The message
    /// prints only names from this server's schema (#37). JSON null is absent.
    static func check(tool: String, arguments: [String: Value]) throws {
        guard let properties = schemas[tool]?.objectValue?["properties"]?.objectValue else { return }
        if let problem = problem(arguments, properties: properties, ownRefusals: refusedByTheHandler[tool] ?? [],
                                 unknownKey: "\(tool) got a key it does not read, and did nothing.") {
            throw ToolError.invalidParameter(problem)
        }
    }

    /// The same for one row of a batch, which fails alone. `checksKeys` is false where the handler
    /// words the unknown-key refusal itself (#441).
    static func rowProblem(tool: String, rowsKey: String, row: [String: Value], index: Int, checksKeys: Bool) -> String? {
        let rows = schemas[tool]?.objectValue?["properties"]?.objectValue?[rowsKey]?.objectValue
        guard let properties = rows?["items"]?.objectValue?["properties"]?.objectValue else { return nil }
        // Beside `recurrence`, a row has the event tools' messages.
        let ownRefusals = checksKeys ? (refusedByTheHandler["create_event"] ?? []) : Set(row.keys)
        return problem(row, properties: properties, ownRefusals: ownRefusals,
                       unknownKey: "Row \(index) has a key this tool does not read. Nothing was written for this row.")
            .map { $0.hasPrefix("Row ") ? $0 : "Row \(index): \($0)" }
    }

    private static func problem(_ object: [String: Value], properties: [String: Value], ownRefusals: Set<String>,
                                unknownKey: String) -> String? {
        guard Set(object.keys).subtracting(ownRefusals).isSubset(of: properties.keys) else {
            return properties.isEmpty ? "\(unknownKey) It takes no arguments."
                : "\(unknownKey) It accepts: \(properties.keys.sorted().joined(separator: ", "))."
        }
        // Sorted, so a call with two problems always gets the same one.
        for key in properties.keys.sorted() {
            guard let value = object[key], let schema = properties[key] else { continue }
            if let expected = expectedType(value, schema: schema) { return "\(key) must be \(expected)." }
            // `recurrence` has its own parser and messages (#434).
            guard key != "recurrence", let nested = schema.objectValue?["properties"]?.objectValue,
                  let inner = value.objectValue else { continue }
            if let problem = problem(inner, properties: nested, ownRefusals: [],
                                     unknownKey: "\(key) has a key this tool does not read, and nothing was done.") {
                return problem
            }
        }
        return nil
    }

    /// What `value` should have been, where a handler's read returns nil on a mismatch. Booleans have
    /// a strict check of their own (#184). A whole-number double is an integer, as in
    /// `InputValidation.requireIntIfPresent`.
    static func expectedType(_ value: Value, schema: Value) -> String? {
        guard value != .null, let type = schema.objectValue?["type"]?.stringValue else { return nil }
        switch type {
        case "string": return value.stringValue == nil ? "a string" : nil
        case "array":
            guard value.arrayValue == nil else { return nil }
            switch schema.objectValue?["items"]?.objectValue?["type"]?.stringValue {
            case "string": return "an array of strings"
            case "integer": return "an array of integers"
            default: return "an array"
            }
        case "integer":
            return value.intValue != nil || value.doubleValue.flatMap({ Int(exactly: $0) }) != nil ? nil : "an integer"
        case "number": return value.doubleValue == nil && value.intValue == nil ? "a number" : nil
        case "object": return value.objectValue == nil ? "an object" : nil
        default: return nil
        }
    }
}
