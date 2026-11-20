import Foundation

/// Represents a connected MCP client session shown in the Dashboard.
public struct ConnectedClientInfo: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let version: String
    public let connectedAt: Date

    public init(
        id: UUID,
        name: String = "Client MCP",
        version: String = "",
        connectedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.connectedAt = connectedAt
    }

    public var displayLabel: String {
        version.isEmpty ? name : "\(name) \(version)"
    }
}

/// Handles a single MCP JSON-RPC 2.0 session over any `NDJSONTransport`,
/// supporting Tools (with annotations), Resources (`macos://...`), and Prompts.
public actor MCPServerSession {
    public let sessionID: UUID
    public let serverInfo: MCPImplementationInfo

    private let registry: MCPToolRegistry
    private let resourceCatalog: MCPResourceCatalog
    private let promptCatalog: MCPPromptCatalog
    private let settings: ToolSettingsStore
    private let permissionManager: PermissionManager
    private let auditLogger: AuditLogger
    private let transport: any NDJSONTransport
    private let onClientUpdated: (@Sendable (ConnectedClientInfo) async -> Void)?

    private var clientInfo: ConnectedClientInfo
    private var negotiatedProtocolVersion: String = MCPProtocolVersion.latest
    private var isInitialized = false

    public init(
        sessionID: UUID = UUID(),
        serverInfo: MCPImplementationInfo = MCPImplementationInfo(name: "MacP", version: "2.0.0"),
        registry: MCPToolRegistry,
        resourceCatalog: MCPResourceCatalog = MCPResourceCatalog(),
        promptCatalog: MCPPromptCatalog = MCPPromptCatalog(),
        settings: ToolSettingsStore,
        permissionManager: PermissionManager,
        auditLogger: AuditLogger,
        transport: any NDJSONTransport,
        onClientUpdated: (@Sendable (ConnectedClientInfo) async -> Void)? = nil
    ) {
        self.sessionID = sessionID
        self.serverInfo = serverInfo
        self.registry = registry
        self.resourceCatalog = resourceCatalog
        self.promptCatalog = promptCatalog
        self.settings = settings
        self.permissionManager = permissionManager
        self.auditLogger = auditLogger
        self.transport = transport
        self.onClientUpdated = onClientUpdated
        self.clientInfo = ConnectedClientInfo(id: sessionID)
    }

    /// Runs the JSON-RPC message processing loop until the transport reaches EOF or closes.
    public func run() async {
        DiagnosticLog.write("MCP session \(sessionID.uuidString.prefix(8)) started")

        for await rawLine in transport.incomingLines() {
            if let response = await handleRawMessage(rawLine) {
                do {
                    let encoded = try JSONRPCCodec.encodeLine(response)
                    try await transport.sendLine(encoded)
                } catch {
                    DiagnosticLog.write("Failed to write MCP response: \(error.localizedDescription)")
                    break
                }
            }
        }

        DiagnosticLog.write("MCP session \(sessionID.uuidString.prefix(8)) ended (\(clientInfo.displayLabel))")
    }

    /// Processes a single raw UTF-8 JSON-RPC 2.0 payload and returns an optional response (nil for notifications).
    public func handleRawMessage(_ rawLine: Data) async -> JSONRPCResponse? {
        let request: JSONRPCRequest
        do {
            request = try JSONRPCCodec.makeDecoder().decode(JSONRPCRequest.self, from: rawLine)
        } catch {
            return JSONRPCResponse(
                id: .null,
                error: .parseError(error.localizedDescription)
            )
        }

        guard request.jsonrpc == "2.0" else {
            guard let id = request.id else { return nil }
            return JSONRPCResponse(
                id: id,
                error: .invalidRequest("jsonrpc must be '2.0'")
            )
        }

        return await route(request: request)
    }

    /// Sends a `notifications/tools/list_changed` notification to this client when toggles or Shield Mode change.
    public func sendToolsListChangedNotification() async {
        guard isInitialized else { return }
        let notification = JSONRPCNotification(method: "notifications/tools/list_changed")
        guard let encoded = try? JSONRPCCodec.encodeLine(notification) else { return }
        try? await transport.sendLine(encoded)
    }

    /// Sends a `notifications/resources/list_changed` notification when available resources change.
    public func sendResourcesListChangedNotification() async {
        guard isInitialized else { return }
        let notification = JSONRPCNotification(method: "notifications/resources/list_changed")
        guard let encoded = try? JSONRPCCodec.encodeLine(notification) else { return }
        try? await transport.sendLine(encoded)
    }

    // MARK: - Routing

    private func route(request: JSONRPCRequest) async -> JSONRPCResponse? {
        if request.isNotification {
            await handleNotification(request)
            return nil
        }

        guard let requestID = request.id else {
            return nil
        }

        switch request.method {
        case "initialize":
            return await handleInitialize(id: requestID, params: request.params)
        case "ping":
            return JSONRPCResponse(id: requestID, result: .object([:]))
        case "tools/list":
            return handleToolsList(id: requestID)
        case "tools/call":
            return await handleToolsCall(id: requestID, params: request.params)
        case "resources/list":
            return handleResourcesList(id: requestID)
        case "resources/read":
            return await handleResourcesRead(id: requestID, params: request.params)
        case "prompts/list":
            return handlePromptsList(id: requestID)
        case "prompts/get":
            return handlePromptsGet(id: requestID, params: request.params)
        default:
            return JSONRPCResponse(id: requestID, error: .methodNotFound(request.method))
        }
    }

    private func handleNotification(_ request: JSONRPCRequest) async {
        switch request.method {
        case "notifications/initialized":
            isInitialized = true
            DiagnosticLog.write("MCP client initialized: \(clientInfo.displayLabel)")
        case "notifications/cancelled":
            break
        default:
            DiagnosticLog.write("Ignored MCP notification: \(request.method)")
        }
    }

    private func handleInitialize(id: JSONRPCID, params: JSONValue?) async -> JSONRPCResponse {
        let initParams: MCPInitializeParams
        if let params {
            do {
                initParams = try JSONValueBridge.fromJSONValue(params, as: MCPInitializeParams.self)
            } catch {
                return JSONRPCResponse(id: id, error: .invalidParams(error.localizedDescription))
            }
        } else {
            initParams = MCPInitializeParams()
        }

        negotiatedProtocolVersion = MCPProtocolVersion.negotiate(requested: initParams.protocolVersion)

        if let incomingClient = initParams.clientInfo {
            let updated = ConnectedClientInfo(
                id: sessionID,
                name: incomingClient.name,
                version: incomingClient.version,
                connectedAt: clientInfo.connectedAt
            )
            clientInfo = updated
            if let onClientUpdated {
                await onClientUpdated(updated)
            }
        }

        let result = MCPInitializeResult(
            protocolVersion: negotiatedProtocolVersion,
            capabilities: MCPServerCapabilities(
                tools: MCPToolCapabilities(listChanged: true),
                resources: MCPResourceCapabilities(subscribe: false, listChanged: true),
                prompts: MCPPromptCapabilities(listChanged: false)
            ),
            serverInfo: serverInfo,
            instructions: "MacP exposes native macOS productivity, workspace, vision, and automation tools plus live macos:// resources and prompts. Sensitive/critical actions require local user approval in the MacP menu bar app."
        )

        return encodeResult(id: id, value: result)
    }

    // MARK: - Tools

    private func handleToolsList(id: JSONRPCID) -> JSONRPCResponse {
        let definitions = registry.definitions(enabledUsing: settings)
        return encodeResult(id: id, value: MCPToolsListResult(tools: definitions))
    }

    private func handleToolsCall(id: JSONRPCID, params: JSONValue?) async -> JSONRPCResponse {
        guard let params else {
            return JSONRPCResponse(id: id, error: .invalidParams("Missing params for tools/call"))
        }

        let callParams: MCPCallToolParams
        do {
            callParams = try JSONValueBridge.fromJSONValue(params, as: MCPCallToolParams.self)
        } catch {
            return JSONRPCResponse(id: id, error: .invalidParams(error.localizedDescription))
        }

        guard let tool = registry.tool(named: callParams.name) else {
            return JSONRPCResponse(id: id, error: .invalidParams("Unknown tool: \(callParams.name)"))
        }

        let arguments = callParams.arguments ?? [:]
        let toolResult = await invokeTool(
            tool,
            arguments: arguments,
            method: "tools/call",
            displayTarget: tool.name
        )
        return encodeResult(id: id, value: toolResult)
    }

    // MARK: - Resources

    private func handleResourcesList(id: JSONRPCID) -> JSONRPCResponse {
        let defs = resourceCatalog.definitions(enabledUsing: settings, registry: registry)
        return encodeResult(id: id, value: MCPResourcesListResult(resources: defs))
    }

    private func handleResourcesRead(id: JSONRPCID, params: JSONValue?) async -> JSONRPCResponse {
        guard let params else {
            return JSONRPCResponse(id: id, error: .invalidParams("Missing params for resources/read"))
        }

        let readParams: MCPReadResourceParams
        do {
            readParams = try JSONValueBridge.fromJSONValue(params, as: MCPReadResourceParams.self)
        } catch {
            return JSONRPCResponse(id: id, error: .invalidParams(error.localizedDescription))
        }

        guard let entry = resourceCatalog.entry(forURI: readParams.uri),
              let backingTool = registry.tool(named: entry.backingToolName) else {
            return JSONRPCResponse(id: id, error: .invalidParams("Unknown resource URI: \(readParams.uri)"))
        }

        let toolResult = await invokeTool(
            backingTool,
            arguments: entry.defaultArguments,
            method: "resources/read",
            displayTarget: readParams.uri
        )

        if toolResult.isError {
            let errMessage = toolResult.content.compactMap(\.text).joined(separator: "\n")
            return JSONRPCResponse(
                id: id,
                error: JSONRPCError(code: -32001, message: errMessage.isEmpty ? "Resource unavailable" : errMessage)
            )
        }

        let textContent = toolResult.content.compactMap(\.text).joined(separator: "\n")
        let readResult = MCPReadResourceResult(contents: [
            MCPResourceContents(
                uri: entry.definition.uri,
                mimeType: entry.definition.mimeType ?? "application/json",
                text: textContent
            )
        ])
        return encodeResult(id: id, value: readResult)
    }

    // MARK: - Prompts

    private func handlePromptsList(id: JSONRPCID) -> JSONRPCResponse {
        encodeResult(id: id, value: MCPPromptsListResult(prompts: promptCatalog.definitions))
    }

    private func handlePromptsGet(id: JSONRPCID, params: JSONValue?) -> JSONRPCResponse {
        guard let params else {
            return JSONRPCResponse(id: id, error: .invalidParams("Missing params for prompts/get"))
        }

        let getParams: MCPGetPromptParams
        do {
            getParams = try JSONValueBridge.fromJSONValue(params, as: MCPGetPromptParams.self)
        } catch {
            return JSONRPCResponse(id: id, error: .invalidParams(error.localizedDescription))
        }

        guard let promptResult = promptCatalog.getPrompt(
            name: getParams.name,
            arguments: getParams.arguments ?? [:]
        ) else {
            return JSONRPCResponse(id: id, error: .invalidParams("Unknown prompt: \(getParams.name)"))
        }

        return encodeResult(id: id, value: promptResult)
    }

    // MARK: - Shared Guarded Tool Execution

    private func invokeTool(
        _ tool: any MCPTool,
        arguments: [String: JSONValue],
        method: String,
        displayTarget: String
    ) async -> MCPCallToolResult {
        let argsValue = JSONValue.object(arguments)
        let argsSummary = argsValue.compactDescription
        let argsJSON = prettyJSONString(argsValue)
        let startTime = Date()

        // 0. Global Shield Mode ("Mode Bouclier") blocks all AI actions immediately.
        if settings.isShieldModeActive {
            let message = "MacP est en Mode Bouclier (pause globale activée par l'utilisateur)."
            await auditLogger.record(AuditEntry(
                clientName: clientInfo.displayLabel,
                method: method,
                toolName: displayTarget,
                argumentsSummary: argsSummary,
                argumentsJSON: argsJSON,
                outcome: .denied,
                durationMs: elapsedMs(since: startTime),
                detail: "Bloqué par le Mode Bouclier",
                resultPreview: message
            ))
            return .failure(message)
        }

        // 1. Check UserDefaults toggle from the Bento Dashboard.
        guard settings.isToolEnabled(tool.name) else {
            let message = "Outil '\(tool.name)' désactivé par l'utilisateur dans MacP."
            await auditLogger.record(AuditEntry(
                clientName: clientInfo.displayLabel,
                method: method,
                toolName: displayTarget,
                argumentsSummary: argsSummary,
                argumentsJSON: argsJSON,
                outcome: .denied,
                durationMs: elapsedMs(since: startTime),
                detail: "Désactivé dans le Dashboard",
                resultPreview: message
            ))
            return .failure(message)
        }

        // 2. Check granular user permission policy (NSAlert for sensitive/critical tools).
        let authorized = await permissionManager.authorize(
            toolName: tool.name,
            toolDisplayName: tool.displayName,
            sensitivity: tool.sensitivity,
            reason: tool.permissionReason,
            clientName: clientInfo.displayLabel,
            argumentsSummary: argsSummary
        )

        guard authorized else {
            let message = "Exécution de '\(tool.name)' refusée par l'utilisateur."
            await auditLogger.record(AuditEntry(
                clientName: clientInfo.displayLabel,
                method: method,
                toolName: displayTarget,
                argumentsSummary: argsSummary,
                argumentsJSON: argsJSON,
                outcome: .denied,
                durationMs: elapsedMs(since: startTime),
                detail: "Refusé par l'utilisateur",
                resultPreview: message
            ))
            return .failure(message)
        }

        // 3. Execute the native macOS tool.
        do {
            let toolResult = try await tool.execute(arguments: arguments)
            let duration = elapsedMs(since: startTime)
            let combinedText = toolResult.content
                .map { block in
                    if let text = block.text { return text }
                    if block.type == "image" {
                        return "[Image \(block.mimeType ?? "image") : \(block.data?.count ?? 0) chars base64]"
                    }
                    return "[\(block.type)]"
                }
                .joined(separator: "\n")

            let shortDetail = combinedText.count > 120
                ? String(combinedText.prefix(117)) + "..."
                : combinedText
            let preview = combinedText.count > 4000
                ? String(combinedText.prefix(3997)) + "..."
                : combinedText

            await auditLogger.record(AuditEntry(
                clientName: clientInfo.displayLabel,
                method: method,
                toolName: displayTarget,
                argumentsSummary: argsSummary,
                argumentsJSON: argsJSON,
                outcome: toolResult.isError ? .error : .success,
                durationMs: duration,
                detail: shortDetail,
                resultPreview: preview
            ))

            return toolResult
        } catch {
            let duration = elapsedMs(since: startTime)
            let errMsg = "Erreur lors de l'exécution de '\(tool.name)' : \(error.localizedDescription)"
            await auditLogger.record(AuditEntry(
                clientName: clientInfo.displayLabel,
                method: method,
                toolName: displayTarget,
                argumentsSummary: argsSummary,
                argumentsJSON: argsJSON,
                outcome: .error,
                durationMs: duration,
                detail: error.localizedDescription,
                resultPreview: errMsg
            ))
            return .failure(errMsg)
        }
    }

    private func encodeResult<T: Encodable>(id: JSONRPCID, value: T) -> JSONRPCResponse {
        do {
            let jsonVal = try JSONValueBridge.toJSONValue(value)
            return JSONRPCResponse(id: id, result: jsonVal)
        } catch {
            return JSONRPCResponse(id: id, error: .internalError(error.localizedDescription))
        }
    }

    private func prettyJSONString(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func elapsedMs(since start: Date) -> Int {
        max(0, Int((Date().timeIntervalSince(start) * 1000.0).rounded()))
    }
}
