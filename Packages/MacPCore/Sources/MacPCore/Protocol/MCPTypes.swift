import Foundation

/// Supported Model Context Protocol revisions.
public enum MCPProtocolVersion {
    public static let latest = "2025-03-26"
    public static let supported: Set<String> = [
        "2024-11-05",
        "2025-03-26",
        "2025-06-18"
    ]

    public static func negotiate(requested: String?) -> String {
        guard let requested else { return latest }
        return supported.contains(requested) ? requested : latest
    }
}

public struct MCPImplementationInfo: Sendable, Equatable, Codable {
    public let name: String
    public let version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public struct MCPInitializeParams: Sendable, Equatable, Codable {
    public let protocolVersion: String?
    public let capabilities: JSONValue?
    public let clientInfo: MCPImplementationInfo?

    public init(
        protocolVersion: String? = nil,
        capabilities: JSONValue? = nil,
        clientInfo: MCPImplementationInfo? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.clientInfo = clientInfo
    }
}

public struct MCPToolCapabilities: Sendable, Equatable, Codable {
    public let listChanged: Bool

    public init(listChanged: Bool = true) {
        self.listChanged = listChanged
    }
}

public struct MCPResourceCapabilities: Sendable, Equatable, Codable {
    public let subscribe: Bool
    public let listChanged: Bool

    public init(subscribe: Bool = false, listChanged: Bool = true) {
        self.subscribe = subscribe
        self.listChanged = listChanged
    }
}

public struct MCPPromptCapabilities: Sendable, Equatable, Codable {
    public let listChanged: Bool

    public init(listChanged: Bool = false) {
        self.listChanged = listChanged
    }
}

public struct MCPServerCapabilities: Sendable, Equatable, Codable {
    public let tools: MCPToolCapabilities
    public let resources: MCPResourceCapabilities?
    public let prompts: MCPPromptCapabilities?

    public init(
        tools: MCPToolCapabilities = MCPToolCapabilities(listChanged: true),
        resources: MCPResourceCapabilities? = MCPResourceCapabilities(subscribe: false, listChanged: true),
        prompts: MCPPromptCapabilities? = MCPPromptCapabilities(listChanged: false)
    ) {
        self.tools = tools
        self.resources = resources
        self.prompts = prompts
    }
}

public struct MCPInitializeResult: Sendable, Equatable, Codable {
    public let protocolVersion: String
    public let capabilities: MCPServerCapabilities
    public let serverInfo: MCPImplementationInfo
    public let instructions: String?

    public init(
        protocolVersion: String,
        capabilities: MCPServerCapabilities = MCPServerCapabilities(),
        serverInfo: MCPImplementationInfo,
        instructions: String? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.serverInfo = serverInfo
        self.instructions = instructions
    }
}

// MARK: - Tools (with MCP 2025-03-26 Annotations & Text/Image Content Blocks)

public struct MCPToolAnnotations: Sendable, Equatable, Codable {
    public let title: String?
    public let readOnlyHint: Bool?
    public let destructiveHint: Bool?
    public let idempotentHint: Bool?
    public let openWorldHint: Bool?

    public init(
        title: String? = nil,
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.title = title
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }
}

public struct MCPToolDefinition: Sendable, Equatable, Codable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue
    public let annotations: MCPToolAnnotations?

    public init(
        name: String,
        description: String,
        inputSchema: JSONValue,
        annotations: MCPToolAnnotations? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }
}

public struct MCPToolsListResult: Sendable, Equatable, Codable {
    public let tools: [MCPToolDefinition]

    public init(tools: [MCPToolDefinition]) {
        self.tools = tools
    }
}

public struct MCPCallToolParams: Sendable, Equatable, Codable {
    public let name: String
    public let arguments: [String: JSONValue]?

    public init(name: String, arguments: [String: JSONValue]? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

public struct MCPContentBlock: Sendable, Equatable, Codable {
    public let type: String
    public let text: String?
    public let data: String?
    public let mimeType: String?

    public init(
        type: String,
        text: String? = nil,
        data: String? = nil,
        mimeType: String? = nil
    ) {
        self.type = type
        self.text = text
        self.data = data
        self.mimeType = mimeType
    }

    public static func text(_ content: String) -> MCPContentBlock {
        MCPContentBlock(type: "text", text: content)
    }

    public static func image(base64Data: String, mimeType: String = "image/jpeg") -> MCPContentBlock {
        MCPContentBlock(type: "image", data: base64Data, mimeType: mimeType)
    }
}

public struct MCPCallToolResult: Sendable, Equatable, Codable {
    public let content: [MCPContentBlock]
    public let isError: Bool

    public init(content: [MCPContentBlock], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func success(_ text: String) -> MCPCallToolResult {
        MCPCallToolResult(content: [.text(text)], isError: false)
    }

    public static func failure(_ message: String) -> MCPCallToolResult {
        MCPCallToolResult(content: [.text(message)], isError: true)
    }
}

// MARK: - MCP Resources

public struct MCPResourceDefinition: Sendable, Equatable, Codable {
    public let uri: String
    public let name: String
    public let description: String?
    public let mimeType: String?

    public init(
        uri: String,
        name: String,
        description: String? = nil,
        mimeType: String? = "application/json"
    ) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
    }
}

public struct MCPResourcesListResult: Sendable, Equatable, Codable {
    public let resources: [MCPResourceDefinition]

    public init(resources: [MCPResourceDefinition]) {
        self.resources = resources
    }
}

public struct MCPReadResourceParams: Sendable, Equatable, Codable {
    public let uri: String

    public init(uri: String) {
        self.uri = uri
    }
}

public struct MCPResourceContents: Sendable, Equatable, Codable {
    public let uri: String
    public let mimeType: String?
    public let text: String?
    public let blob: String?

    public init(
        uri: String,
        mimeType: String? = "application/json",
        text: String? = nil,
        blob: String? = nil
    ) {
        self.uri = uri
        self.mimeType = mimeType
        self.text = text
        self.blob = blob
    }
}

public struct MCPReadResourceResult: Sendable, Equatable, Codable {
    public let contents: [MCPResourceContents]

    public init(contents: [MCPResourceContents]) {
        self.contents = contents
    }
}

// MARK: - MCP Prompts

public struct MCPPromptArgument: Sendable, Equatable, Codable {
    public let name: String
    public let description: String?
    public let required: Bool?

    public init(name: String, description: String? = nil, required: Bool? = false) {
        self.name = name
        self.description = description
        self.required = required
    }
}

public struct MCPPromptDefinition: Sendable, Equatable, Codable {
    public let name: String
    public let description: String?
    public let arguments: [MCPPromptArgument]?

    public init(
        name: String,
        description: String? = nil,
        arguments: [MCPPromptArgument]? = nil
    ) {
        self.name = name
        self.description = description
        self.arguments = arguments
    }
}

public struct MCPPromptsListResult: Sendable, Equatable, Codable {
    public let prompts: [MCPPromptDefinition]

    public init(prompts: [MCPPromptDefinition]) {
        self.prompts = prompts
    }
}

public struct MCPGetPromptParams: Sendable, Equatable, Codable {
    public let name: String
    public let arguments: [String: String]?

    public init(name: String, arguments: [String: String]? = nil) {
        self.name = name
        self.arguments = arguments
    }
}

public struct MCPPromptMessage: Sendable, Equatable, Codable {
    public let role: String
    public let content: MCPContentBlock

    public init(role: String = "user", content: MCPContentBlock) {
        self.role = role
        self.content = content
    }
}

public struct MCPGetPromptResult: Sendable, Equatable, Codable {
    public let description: String?
    public let messages: [MCPPromptMessage]

    public init(description: String? = nil, messages: [MCPPromptMessage]) {
        self.description = description
        self.messages = messages
    }
}

/// Helper to convert any `Encodable` value into `JSONValue`.
public enum JSONValueBridge {
    public static func toJSONValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONRPCCodec.makeEncoder().encode(value)
        return try JSONRPCCodec.makeDecoder().decode(JSONValue.self, from: data)
    }

    public static func fromJSONValue<T: Decodable>(_ value: JSONValue, as type: T.Type) throws -> T {
        let data = try JSONRPCCodec.makeEncoder().encode(value)
        return try JSONRPCCodec.makeDecoder().decode(type, from: data)
    }
}
