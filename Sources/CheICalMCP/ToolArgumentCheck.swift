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
    /// prints only names from this server's schema (#37). JSON null on a declared key passes this
    /// check, and a handler may still refuse it; on an undeclared key it is refused like any other
    /// value, since `delete_calendar` depends on a misspelled key failing whatever it holds (#328).
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
        // `recurrence` has its own parser and messages (#184, #434).
        for key in properties.keys.sorted() where key != "recurrence" {
            guard let value = object[key], let schema = properties[key] else { continue }
            if let expected = expectedType(value, schema: schema) { return "\(key) must be \(expected)." }
            guard let nested = schema.objectValue?["properties"]?.objectValue, let inner = value.objectValue else { continue }
            if let problem = problem(inner, properties: nested, ownRefusals: [],
                                     unknownKey: "\(key) has a key this tool does not read, and nothing was done.") {
                return problem
            }
        }
        return nil
    }

    /// What `value` should have been, where a handler's read returns nil on a mismatch. Booleans have
    /// a strict check of their own (#184). A whole-number double is an integer, as in
    /// `InputValidation.requireIntIfPresent`. Elements are checked where `items.type` is `string` or
    /// `integer`: handlers read those arrays with `compactMap` and would drop the rest (PR #463 verify);
    /// an element cannot be null, since a null there would be dropped too. `.data` is text the SDK
    /// read as a data URL, on the MCP path: the caller sent a string, so the message says why it failed.
    static func expectedType(_ value: Value, schema: Value) -> String? {
        guard value != .null, let type = schema.objectValue?["type"]?.stringValue else { return nil }
        switch type {
        case "string":
            if case .data = value { return "a string; text of the form data:<type>,<content> is read as a data URL, not as text, so reword its start" }
            return value.stringValue == nil ? "a string" : nil
        case "array":
            let items = schema.objectValue?["items"]
            let name: String
            switch items?.objectValue?["type"]?.stringValue {
            case "string": name = "an array of strings"
            case "integer": name = "an array of integers"
            default: name = "an array"
            }
            guard let array = value.arrayValue else { return name }
            guard name != "an array", let items else { return nil }
            return array.contains { $0 == .null || expectedType($0, schema: items) != nil } ? name : nil
        case "integer":
            return value.intValue != nil || value.doubleValue.flatMap({ Int(exactly: $0) }) != nil ? nil : "an integer"
        case "number": return InputValidation.number(value) == nil ? "a number" : nil
        case "object": return value.objectValue == nil ? "an object" : nil
        default: return nil
        }
    }
}
