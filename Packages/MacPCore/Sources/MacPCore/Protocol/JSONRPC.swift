import Foundation

/// A JSON-RPC 2.0 request/response identifier (string, integer, or null).
public enum JSONRPCID: Sendable, Equatable, Hashable, Codable {
    case int(Int)
    case string(String)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCID.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "JSON-RPC id must be a string, integer, or null"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .int(v):
            try container.encode(v)
        case let .string(v):
            try container.encode(v)
        case .null:
            try container.encodeNil()
        }
    }
}

/// Incoming JSON-RPC 2.0 request or notification.
public struct JSONRPCRequest: Sendable, Equatable, Codable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let method: String
    public let params: JSONValue?

    public var isNotification: Bool {
        id == nil
    }

    public init(
        jsonrpc: String = "2.0",
        id: JSONRPCID? = nil,
        method: String,
        params: JSONValue? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

/// Standard JSON-RPC 2.0 error object.
public struct JSONRPCError: Sendable, Equatable, Codable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static func parseError(_ detail: String? = nil) -> JSONRPCError {
        JSONRPCError(code: -32700, message: "Parse error", data: detail.map(JSONValue.string))
    }

    public static func invalidRequest(_ detail: String? = nil) -> JSONRPCError {
        JSONRPCError(code: -32600, message: "Invalid Request", data: detail.map(JSONValue.string))
    }

    public static func methodNotFound(_ method: String) -> JSONRPCError {
        JSONRPCError(code: -32601, message: "Method not found: \(method)")
    }

    public static func invalidParams(_ detail: String) -> JSONRPCError {
        JSONRPCError(code: -32602, message: "Invalid params: \(detail)")
    }

    public static func internalError(_ detail: String) -> JSONRPCError {
        JSONRPCError(code: -32603, message: "Internal error: \(detail)")
    }
}

/// Outgoing JSON-RPC 2.0 response.
public struct JSONRPCResponse: Sendable, Equatable, Codable {
    public let jsonrpc: String
    public let id: JSONRPCID
    public let result: JSONValue?
    public let error: JSONRPCError?

    public init(id: JSONRPCID, result: JSONValue) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = result
        self.error = nil
    }

    public init(id: JSONRPCID, error: JSONRPCError) {
        self.jsonrpc = "2.0"
        self.id = id
        self.result = nil
        self.error = error
    }

    private enum CodingKeys: String, CodingKey {
        case jsonrpc, id, result, error
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jsonrpc, forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        if let error {
            try container.encode(error, forKey: .error)
        } else if let result {
            try container.encode(result, forKey: .result)
        } else {
            try container.encode(JSONValue.object([:]), forKey: .result)
        }
    }
}

/// Outgoing JSON-RPC 2.0 notification (no id).
public struct JSONRPCNotification: Sendable, Equatable, Codable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
    }
}

public enum JSONRPCCodec {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    /// Encodes a Codable message as a single newline-terminated UTF-8 JSON line (NDJSON).
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try makeEncoder().encode(value)
        data.append(0x0A) // '\n'
        return data
    }
}
