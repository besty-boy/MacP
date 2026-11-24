import Foundation

/// A strictly typed, `Sendable` JSON value representation for JSON-RPC 2.0 and MCP payloads.
public enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case let .int(value):
            return value
        case let .double(value) where value.rounded() == value && value >= Double(Int.min) && value <= Double(Int.max):
            return Int(value)
        default:
            return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case let .double(value): return value
        case let .int(value): return Double(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Compact, human-readable summary suitable for audit logs.
    public var compactDescription: String {
        switch self {
        case .null:
            return "null"
        case let .bool(v):
            return v ? "true" : "false"
        case let .int(v):
            return String(v)
        case let .double(v):
            return String(v)
        case let .string(v):
            return v.count > 60 ? "\"\(v.prefix(57))...\"" : "\"\(v)\""
        case let .array(items):
            return "[\(items.count) items]"
        case let .object(dict):
            if dict.isEmpty { return "{}" }
            let pairs = dict.keys.sorted().prefix(4).map { key in
                "\(key): \(dict[key]?.compactDescription ?? "null")"
            }
            let suffix = dict.count > 4 ? ", ..." : ""
            return "{\(pairs.joined(separator: ", "))\(suffix)}"
        }
    }

    /// Detailed, readable formatting for user consent prompts (preserves scripts and multiline arguments).
    public func detailedPreview(maxLength: Int = 1200) -> String {
        let rendered: String
        switch self {
        case let .object(dict):
            if dict.isEmpty {
                return "{}"
            }
            let lines = dict.keys.sorted().map { key -> String in
                guard let value = dict[key] else { return "\(key): null" }
                switch value {
                case let .string(text):
                    if text.contains("\n") {
                        return "\(key):\n\(text)"
                    }
                    return "\(key): \(text)"
                default:
                    return "\(key): \(value.compactDescription)"
                }
            }
            rendered = lines.joined(separator: "\n")
        default:
            rendered = compactDescription
        }

        if rendered.count > maxLength {
            return String(rendered.prefix(max(0, maxLength - 3))) + "..."
        }
        return rendered
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let double = try? container.decode(Double.self) {
            self = .double(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}
