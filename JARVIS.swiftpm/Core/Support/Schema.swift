import Foundation

/// Small helpers for writing tool input schemas without hand-building JSON.
public enum Schema {
    public static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": false,
        ])
    }

    public static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    public static func enumeration(_ values: [String], _ description: String) -> JSONValue {
        ["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(description)]
    }

    public static func integer(_ description: String) -> JSONValue {
        ["type": "integer", "description": .string(description)]
    }

    public static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    public static func stringArray(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }
}

/// Typed, validated reads from a tool's input. Tool inputs come from the
/// model, so they are validated before any executor touches them.
public struct ToolArguments: Sendable {
    public let raw: JSONValue

    public init(_ raw: JSONValue) { self.raw = raw }

    public func string(_ key: String) throws -> String {
        guard let value = raw[key]?.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.invalidArguments("Missing required argument '\(key)'.")
        }
        return value
    }

    public func optionalString(_ key: String) -> String? {
        guard let value = raw[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    public func optionalInt(_ key: String) -> Int? { raw[key]?.intValue }

    public func optionalBool(_ key: String) -> Bool? { raw[key]?.boolValue }

    public func stringArray(_ key: String) -> [String] {
        raw[key]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// Parses ISO-8601 dates with or without a time-zone designator. Dates
    /// without a zone are interpreted in the device's current time zone.
    public func date(_ key: String) throws -> Date {
        let text = try string(key)
        guard let date = DateParsing.parse(text) else {
            throw ToolError.invalidArguments("'\(key)' must be an ISO-8601 date such as 2026-10-03T15:00:00.")
        }
        return date
    }

    public func optionalDate(_ key: String) throws -> Date? {
        guard optionalString(key) != nil else { return nil }
        return try date(key)
    }
}

public enum DateParsing {
    public static func parse(_ text: String, timeZone: TimeZone = .current) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: text) { return date }

        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    public static func localISO(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter.string(from: date)
    }
}
