import Foundation

/// Logical category used to organize MCP tools in the Bento Dashboard UI.
public enum ToolCategory: String, Sendable, Codable, CaseIterable, Identifiable {
    case productivity
    case workspace
    case vision
    case automation

    public var id: String { rawValue }

    public var frenchTitle: String {
        switch self {
        case .productivity: return "Productivité"
        case .workspace: return "Système"
        case .vision: return "Vision"
        case .automation: return "Automation"
        }
    }

    public var symbolName: String {
        switch self {
        case .productivity: return "calendar.badge.checkmark"
        case .workspace: return "macwindow"
        case .vision: return "camera.viewfinder"
        case .automation: return "bolt.badge.automatic"
        }
    }
}

/// Metadata describing an MCP tool for both the protocol and the macOS Bento Dashboard UI.
public struct MCPToolMetadata: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let displayName: String
    public let shortSubtitle: String
    public let symbolName: String
    public let category: ToolCategory
    public let sensitivity: ToolSensitivity
    public let permissionReason: String

    public init(
        name: String,
        displayName: String,
        shortSubtitle: String,
        symbolName: String,
        category: ToolCategory = .productivity,
        sensitivity: ToolSensitivity,
        permissionReason: String
    ) {
        self.name = name
        self.displayName = displayName
        self.shortSubtitle = shortSubtitle
        self.symbolName = symbolName
        self.category = category
        self.sensitivity = sensitivity
        self.permissionReason = permissionReason
    }
}

/// Contract implemented by every native macOS MCP tool.
public protocol MCPTool: Sendable {
    var name: String { get }
    var displayName: String { get }
    var shortSubtitle: String { get }
    var symbolName: String { get }
    var category: ToolCategory { get }
    var description: String { get }
    var sensitivity: ToolSensitivity { get }
    var permissionReason: String { get }
    var inputSchema: JSONValue { get }
    var annotations: MCPToolAnnotations { get }

    func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult
}

extension MCPTool {
    public var category: ToolCategory { .productivity }

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: displayName,
            readOnlyHint: sensitivity == .standard,
            destructiveHint: sensitivity == .critical,
            idempotentHint: sensitivity == .standard,
            openWorldHint: false
        )
    }

    public var definition: MCPToolDefinition {
        MCPToolDefinition(
            name: name,
            description: description,
            inputSchema: inputSchema,
            annotations: annotations
        )
    }

    public var metadata: MCPToolMetadata {
        MCPToolMetadata(
            name: name,
            displayName: displayName,
            shortSubtitle: shortSubtitle,
            symbolName: symbolName,
            category: category,
            sensitivity: sensitivity,
            permissionReason: permissionReason
        )
    }
}

/// Immutable registry of all available macOS MCP tools.
public struct MCPToolRegistry: Sendable {
    private let orderedTools: [any MCPTool]
    private let toolsByName: [String: any MCPTool]
    private let cachedDefinitions: [String: MCPToolDefinition]
    private let cachedTokenCostByName: [String: Int]

    public init(tools: [any MCPTool]) {
        self.orderedTools = tools
        self.toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

        let encoder = JSONRPCCodec.makeEncoder()
        var defs: [String: MCPToolDefinition] = [:]
        var costs: [String: Int] = [:]
        defs.reserveCapacity(tools.count)
        costs.reserveCapacity(tools.count)

        for tool in tools {
            let def = tool.definition
            defs[tool.name] = def
            let bytes = (try? encoder.encode(def).count) ?? 0
            costs[tool.name] = TokenEstimator.estimate(utf8Bytes: bytes)
        }

        self.cachedDefinitions = defs
        self.cachedTokenCostByName = costs
    }

    public static func defaultMacOSTools() -> MCPToolRegistry {
        MCPToolRegistry(tools: [
            // Productivité Apple
            ListShortcutsTool(),
            ShortcutTool(),
            ClipboardTool(),
            WriteClipboardTool(),
            CalendarEventsTool(),
            CreateCalendarEventTool(),
            ListRemindersTool(),
            CreateReminderTool(),
            CompleteReminderTool(),
            SpotlightSearchTool(),
            NotificationTool(),
            // Workspace & Système
            SystemStatsTool(),
            RunningAppsTool(),
            OpenAppOrURLTool(),
            SystemControlsTool(),
            // Vision
            ScreenCaptureTool(),
            // Automatisation Pro
            AppleScriptTool()
        ])
    }

    public var allTools: [any MCPTool] {
        orderedTools
    }

    public var allMetadata: [MCPToolMetadata] {
        orderedTools.map(\.metadata)
    }

    public func tool(named name: String) -> (any MCPTool)? {
        toolsByName[name]
    }

    public func definitions(enabledUsing settings: ToolSettingsStore) -> [MCPToolDefinition] {
        guard !settings.isShieldModeActive else {
            return []
        }
        return orderedTools.compactMap { tool in
            guard settings.isToolEnabled(tool.name) else { return nil }
            return cachedDefinitions[tool.name]
        }
    }

    /// Estimates the LLM context token cost of the currently advertised `tools/list` schema.
    public func estimatedSchemaTokens(enabledUsing settings: ToolSettingsStore) -> Int {
        guard !settings.isShieldModeActive else { return 0 }
        var total = 0
        for tool in orderedTools where settings.isToolEnabled(tool.name) {
            total += cachedTokenCostByName[tool.name] ?? 0
        }
        return total
    }

    /// Estimates the schema token cost of a single tool.
    public func estimatedSchemaTokens(forToolNamed name: String) -> Int {
        cachedTokenCostByName[name] ?? 0
    }
}

/// Encodes structured tool outputs as compact JSON (no wasted indentation/newlines) to save 25–40% LLM tokens.
enum ToolOutputFormatter {
    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
