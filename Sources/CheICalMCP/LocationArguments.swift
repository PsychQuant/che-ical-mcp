import EventKit
import MCP

/// #473: `structured_location` and `location_trigger`, read from a tool call. A value outside what
/// the argument takes is refused with a message naming the argument and the values it takes; before,
/// a radius of 0 or less became 100 or was dropped, half a coordinate pair was dropped, and any
/// proximity other than `"leave"` was written as enter. The messages print only names from this
/// server's schema and its own bounds, never the value given (#37).
enum LocationArguments {
    static let latitudeRange = -90.0...90.0
    static let longitudeRange = -180.0...180.0
    /// The `location_trigger` radius when none is given, as its schema says.
    static let defaultTriggerRadius = 100.0

    /// `structured_location`: coordinates are optional, but both or neither.
    static func structuredLocation(_ dict: [String: Value]) throws -> StructuredLocationInput {
        let name = "structured_location"
        guard let title = dict["title"]?.stringValue else {
            throw ToolError.invalidParameter("\(name).title is required")
        }
        let latitude = try coordinate(dict, name: name, key: "latitude", range: latitudeRange)
        let longitude = try coordinate(dict, name: name, key: "longitude", range: longitudeRange)
        switch (latitude, longitude) {
        case (.some, nil):
            throw ToolError.invalidParameter("\(name).longitude is required when latitude is given: give both coordinates or neither")
        case (nil, .some):
            throw ToolError.invalidParameter("\(name).latitude is required when longitude is given: give both coordinates or neither")
        default:
            break
        }
        let radius = try positiveRadius(dict, name: name, omitted: "omit it to set none")
        return StructuredLocationInput(title: title, latitude: latitude, longitude: longitude, radius: radius)
    }

    /// `location_trigger`: title, both coordinates and proximity are required, as its schema says.
    static func locationTrigger(_ dict: [String: Value]) throws -> LocationTriggerInput {
        let name = "location_trigger"
        guard let title = dict["title"]?.stringValue else {
            throw ToolError.invalidParameter("\(name).title is required")
        }
        guard let latitude = try coordinate(dict, name: name, key: "latitude", range: latitudeRange) else {
            throw ToolError.invalidParameter("\(name).latitude is required")
        }
        guard let longitude = try coordinate(dict, name: name, key: "longitude", range: longitudeRange) else {
            throw ToolError.invalidParameter("\(name).longitude is required")
        }
        let radius = try positiveRadius(dict, name: name, omitted: "omit it for the default \(Int(defaultTriggerRadius))")
            ?? defaultTriggerRadius
        let proximity: EKAlarmProximity
        switch dict["proximity"] {
        case nil, .null?:
            throw ToolError.invalidParameter(#"\#(name).proximity is required: "enter" or "leave""#)
        case .string("enter")?:
            proximity = .enter
        case .string("leave")?:
            proximity = .leave
        default:
            throw ToolError.invalidParameter(#"\#(name).proximity must be "enter" or "leave" (lowercase)"#)
        }
        return LocationTriggerInput(title: title, latitude: latitude, longitude: longitude, radius: radius, proximity: proximity)
    }

    /// The coordinate under `key`, nil when it is absent or JSON null.
    private static func coordinate(_ dict: [String: Value], name: String, key: String,
                                   range: ClosedRange<Double>) throws -> Double? {
        guard let value = InputValidation.number(dict[key]) else { return nil }
        guard range.contains(value) else {
            throw ToolError.invalidParameter(
                "\(name).\(key) must be a number from \(Int(range.lowerBound)) to \(Int(range.upperBound))")
        }
        return value
    }

    /// The radius in meters, nil when it is absent or JSON null; 0 or less is refused, not replaced.
    private static func positiveRadius(_ dict: [String: Value], name: String, omitted: String) throws -> Double? {
        guard let radius = InputValidation.number(dict["radius"]) else { return nil }
        guard radius > 0 else {
            throw ToolError.invalidParameter("\(name).radius must be greater than 0, in meters (\(omitted))")
        }
        return radius
    }
}
