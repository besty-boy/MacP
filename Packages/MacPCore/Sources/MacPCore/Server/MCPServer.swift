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
/// supporting concurrent request execution, `notifications/cancelled`, single-pass JSON encoding,
/// Tools (with annotations), Resources (`macos://...`), and Prompts.
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

    private let decoder: JSONDecoder = JSONRPCCodec.makeDecoder()
    private let encoder: JSONEncoder = JSONRPCCodec.makeEncoder()

    private var clientInfo: ConnectedClientInfo
    private var negotiatedProtocolVersion: String = MCPProtocolVersion.latest
    private var isInitialized = false
    private var inFlightTasks: [JSONRPCID: Task<Void, Never>] = [:]

    public init(
        sessionID: UUID = UUID(),
        serverInfo: MCPImplementationInfo = MCPImplementationInfo(name: "MacP", version: MacPVersion.current),
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
    /// Tool/resource calls execute concurrently so slow operations never head-of-line block `ping` or `notifications/cancelled`.
    public func run() async {
        DiagnosticLog.write("MCP session \(sessionID.uuidString.prefix(8)) started")

        for await rawLine in transport.incomingLines() {
            let request: JSONRPCRequest
            do {
                request = try decoder.decode(JSONRPCRequest.self, from: rawLine)
            } catch {
                await sendEncodedLine(try? JSONRPCCodec.encodeErrorLine(
                    id: .null,
                    error: .parseError(error.localizedDescription),
                    using: encoder
                ))
                continue
            }

            guard request.jsonrpc == "2.0" else {
                if let id = request.id {
                    await sendEncodedLine(try? JSONRPCCodec.encodeErrorLine(
                        id: id,
                        error: .invalidRequest("jsonrpc must be '2.0'"),
                        using: encoder
                    ))
                }
                continue
            }

            if request.isNotification {
                handleNotification(request)
                continue
            }

            guard let requestID = request.id else { continue }

            // Process `initialize` synchronously to establish protocol version & client identity before any tool calls.
            if request.method == "initialize" {
                let encoded = await executeDirectLine(request: request, id: requestID)
                await sendEncodedLine(encoded)
                continue
            }

            // Fast synchronous metadata queries avoid task spawn overhead.
            switch request.method {
            case "ping", "tools/list", "resources/list", "resources/templates/list", "prompts/list", "prompts/get":
                let encoded = await executeDirectLine(request: request, id: requestID)
                await sendEncodedLine(encoded)
                continue
            default:
                break
            }

            // Concurrent execution for potentially long-running calls (`tools/call`, `resources/read`).
            inFlightTasks[requestID]?.cancel()
            let task = Task { [weak self] in
                guard let self else { return }
                let encoded = await self.executeDirectLine(request: request, id: requestID)
                if !Task.isCancelled {
                    await self.sendEncodedLine(encoded)
                }
                await self.clearInFlightTask(for: requestID)
            }
            inFlightTasks[requestID] = task
        }

        // On half-closed stdio pipes (e.g. piped CLI commands), let in-flight requests finish writing to stdout.
        // On full-duplex socket disconnects, cancel in-flight work immediately so no orphaned subprocesses keep running.
        let remaining = Array(inFlightTasks.values)
        inFlightTasks.removeAll()
        if !transport.supportsHalfClose {
            for task in remaining {
                task.cancel()
            }
        }
        for task in remaining {
            await task.value
        }

        DiagnosticLog.write("MCP session \(sessionID.uuidString.prefix(8)) ended (\(clientInfo.displayLabel))")
    }

    /// Processes a single raw UTF-8 JSON-RPC 2.0 payload and returns an optional `JSONRPCResponse` (nil for notifications).
    /// Useful for direct invocation and unit tests.
    public func handleRawMessage(_ rawLine: Data) async -> JSONRPCResponse? {
        let request: JSONRPCRequest
        do {
            request = try decoder.decode(JSONRPCRequest.self, from: rawLine)
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

        if request.isNotification {
            handleNotification(request)
            return nil
        }

        guard let requestID = request.id else { return nil }
        guard let encodedLine = await executeDirectLine(request: request, id: requestID) else {
            return nil
        }
        return try? decoder.decode(JSONRPCResponse.self, from: encodedLine)
    }

    /// Sends a `notifications/tools/list_changed` notification to this client when toggles or Shield Mode change.
    public func sendToolsListChangedNotification() async {
        guard isInitialized else { return }
        let notification = JSONRPCNotification(method: "notifications/tools/list_changed")
        guard let encoded = try? JSONRPCCodec.encodeLine(notification, using: encoder) else { return }
        try? await transport.sendLine(encoded)
    }

    /// Sends a `notifications/resources/list_changed` notification when available resources change.
    public func sendResourcesListChangedNotification() async {
        guard isInitialized else { return }
        let notification = JSONRPCNotification(method: "notifications/resources/list_changed")
        guard let encoded = try? JSONRPCCodec.encodeLine(notification, using: encoder) else { return }
        try? await transport.sendLine(encoded)
    }

    // MARK: - Single-Pass Direct Request Execution

    private func clearInFlightTask(for id: JSONRPCID) {
        inFlightTasks.removeValue(forKey: id)
    }

    private func sendEncodedLine(_ data: Data?) async {
        guard let data else { return }
        do {
            try await transport.sendLine(data)
        } catch {
            DiagnosticLog.write("Failed to write MCP response: \(error.localizedDescription)")
        }
    }

    private func handleNotification(_ request: JSONRPCRequest) {
        switch request.method {
        case "notifications/initialized":
            isInitialized = true
            DiagnosticLog.write("MCP client initialized: \(clientInfo.displayLabel)")

        case "notifications/cancelled":
            if let params = request.params,
               let cancelParams = try? decodeParams(params, as: MCPCancelledNotificationParams.self),
               let runningTask = inFlightTasks.removeValue(forKey: cancelParams.requestId) {
                runningTask.cancel()
                DiagnosticLog.write("Cancelled MCP request \(cancelParams.requestId): \(cancelParams.reason ?? "client requested")")
            }

        default:
            DiagnosticLog.write("Ignored MCP notification: \(request.method)")
        }
    }

    /// Executes a request and serializes the response in a single JSON encoding pass (zero `JSONValue` round-trip).
    private func executeDirectLine(request: JSONRPCRequest, id: JSONRPCID) async -> Data? {
        switch request.method {
        case "initialize":
            return await handleInitialize(id: id, params: request.params)

        case "ping":
            return encodeDirectSuccess(id: id, result: [String: JSONValue]())

        case "tools/list":
            let definitions = registry.definitions(enabledUsing: settings)
            return encodeDirectSuccess(id: id, result: MCPToolsListResult(tools: definitions))

        case "tools/call":
            return await handleToolsCall(id: id, params: request.params)

        case "resources/list":
            let defs = resourceCatalog.definitions(enabledUsing: settings, registry: registry)
            return encodeDirectSuccess(id: id, result: MCPResourcesListResult(resources: defs))

        case "resources/templates/list":
            return encodeDirectSuccess(id: id, result: MCPResourceTemplatesListResult(resourceTemplates: []))

        case "resources/read":
            return await handleResourcesRead(id: id, params: request.params)

        case "prompts/list":
            return encodeDirectSuccess(id: id, result: MCPPromptsListResult(prompts: promptCatalog.definitions))

        case "prompts/get":
            return handlePromptsGet(id: id, params: request.params)

        default:
            return encodeDirectError(id: id, error: .methodNotFound(request.method))
        }
    }

    private func handleInitialize(id: JSONRPCID, params: JSONValue?) async -> Data? {
        let initParams: MCPInitializeParams
        if let params {
            do {
                initParams = try decodeParams(params, as: MCPInitializeParams.self)
            } catch {
                return encodeDirectError(id: id, error: .invalidParams(error.localizedDescription))
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
            instructions: "Native macOS MCP bridge (tools, macos:// resources, prompts). Sensitive actions prompt locally in MacP."
        )

        return encodeDirectSuccess(id: id, result: result)
    }

    // MARK: - Tools

    private func handleToolsCall(id: JSONRPCID, params: JSONValue?) async -> Data? {
        guard let params else {
            return encodeDirectError(id: id, error: .invalidParams("Missing params for tools/call"))
        }

        let callParams: MCPCallToolParams
        do {
            callParams = try decodeParams(params, as: MCPCallToolParams.self)
        } catch {
            return encodeDirectError(id: id, error: .invalidParams(error.localizedDescription))
        }

        guard let tool = registry.tool(named: callParams.name) else {
            return encodeDirectError(id: id, error: .invalidParams("Unknown tool: \(callParams.name)"))
        }

        let arguments = callParams.arguments ?? [:]
        let toolResult = await invokeTool(
            tool,
            arguments: arguments,
            method: "tools/call",
            displayTarget: tool.name
        )
        return encodeDirectSuccess(id: id, result: toolResult)
    }

    // MARK: - Resources

    private func handleResourcesRead(id: JSONRPCID, params: JSONValue?) async -> Data? {
        guard let params else {
            return encodeDirectError(id: id, error: .invalidParams("Missing params for resources/read"))
        }

        let readParams: MCPReadResourceParams
        do {
            readParams = try decodeParams(params, as: MCPReadResourceParams.self)
        } catch {
            return encodeDirectError(id: id, error: .invalidParams(error.localizedDescription))
        }

        guard let entry = resourceCatalog.entry(forURI: readParams.uri),
              let backingTool = registry.tool(named: entry.backingToolName) else {
            return encodeDirectError(id: id, error: .invalidParams("Unknown resource URI: \(readParams.uri)"))
        }

        let toolResult = await invokeTool(
            backingTool,
            arguments: entry.defaultArguments,
            method: "resources/read",
            displayTarget: readParams.uri
        )

        if toolResult.isError {
            let errMessage = toolResult.content.compactMap(\.text).joined(separator: "\n")
            return encodeDirectError(
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
        return encodeDirectSuccess(id: id, result: readResult)
    }

    // MARK: - Prompts

    private func handlePromptsGet(id: JSONRPCID, params: JSONValue?) -> Data? {
        guard let params else {
            return encodeDirectError(id: id, error: .invalidParams("Missing params for prompts/get"))
        }

        let getParams: MCPGetPromptParams
        do {
            getParams = try decodeParams(params, as: MCPGetPromptParams.self)
        } catch {
            return encodeDirectError(id: id, error: .invalidParams(error.localizedDescription))
        }

        guard let promptResult = promptCatalog.getPrompt(
            name: getParams.name,
            arguments: getParams.arguments ?? [:]
        ) else {
            return encodeDirectError(id: id, error: .invalidParams("Unknown prompt: \(getParams.name)"))
        }

        return encodeDirectSuccess(id: id, result: promptResult)
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
        let argsDetail = argsValue.detailedPreview(maxLength: 1400)
        let argsJSON = compactJSONString(argsValue)
        let startInstant = ContinuousClock.now
        let currentClient = clientInfo.displayLabel

        // 0. Global Shield Mode ("Mode Bouclier") blocks all AI actions immediately.
        if settings.isShieldModeActive {
            let message = "MacP est en Mode Bouclier (pause globale activée par l'utilisateur)."
            await recordAudit(
                clientName: currentClient,
                method: method,
                target: displayTarget,
                argsSummary: argsSummary,
                argsJSON: argsJSON,
                outcome: .denied,
                since: startInstant,
                detail: "Bloqué par le Mode Bouclier",
                resultPreview: message,
                responseBytes: message.utf8.count
            )
            return .failure(message)
        }

        // 1. Check UserDefaults toggle from the Bento Dashboard.
        guard settings.isToolEnabled(tool.name) else {
            let message = "Outil '\(tool.name)' désactivé par l'utilisateur dans MacP."
            await recordAudit(
                clientName: currentClient,
                method: method,
                target: displayTarget,
                argsSummary: argsSummary,
                argsJSON: argsJSON,
                outcome: .denied,
                since: startInstant,
                detail: "Désactivé dans le Dashboard",
                resultPreview: message,
                responseBytes: message.utf8.count
            )
            return .failure(message)
        }

        // 2. Check granular user permission policy (serialized NSAlert for sensitive/critical tools).
        let authorized = await permissionManager.authorize(
            toolName: tool.name,
            toolDisplayName: tool.displayName,
            sensitivity: tool.sensitivity,
            reason: tool.permissionReason,
            clientName: currentClient,
            argumentsSummary: argsSummary,
            argumentsDetail: argsDetail
        )

        if Task.isCancelled {
            return .failure("Requête annulée par le client MCP.")
        }

        guard authorized else {
            let message = "Exécution de '\(tool.name)' refusée par l'utilisateur."
            await recordAudit(
                clientName: currentClient,
                method: method,
                target: displayTarget,
                argsSummary: argsSummary,
                argsJSON: argsJSON,
                outcome: .denied,
                since: startInstant,
                detail: "Refusé par l'utilisateur",
                resultPreview: message,
                responseBytes: message.utf8.count
            )
            return .failure(message)
        }

        // 3. Execute the native macOS tool.
        do {
            let toolResult = try await tool.execute(arguments: arguments)
            if Task.isCancelled {
                return .failure("Requête annulée par le client MCP.")
            }

            var totalBytes = 0
            let combinedText = toolResult.content
                .map { block -> String in
                    if let text = block.text {
                        totalBytes += text.utf8.count
                        return text
                    }
                    if block.type == "image" {
                        let base64Count = block.data?.utf8.count ?? 0
                        totalBytes += base64Count
                        return "[Image \(block.mimeType ?? "image") : \(base64Count) chars base64]"
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

            await recordAudit(
                clientName: currentClient,
                method: method,
                target: displayTarget,
                argsSummary: argsSummary,
                argsJSON: argsJSON,
                outcome: toolResult.isError ? .error : .success,
                since: startInstant,
                detail: shortDetail,
                resultPreview: preview,
                responseBytes: totalBytes
            )

            return toolResult
        } catch is CancellationError {
            return .failure("Requête annulée par le client MCP.")
        } catch {
            let errMsg = "Erreur lors de l'exécution de '\(tool.name)' : \(error.localizedDescription)"
            await recordAudit(
                clientName: currentClient,
                method: method,
                target: displayTarget,
                argsSummary: argsSummary,
                argsJSON: argsJSON,
                outcome: .error,
                since: startInstant,
                detail: error.localizedDescription,
                resultPreview: errMsg,
                responseBytes: errMsg.utf8.count
            )
            return .failure(errMsg)
        }
    }

    // MARK: - Helpers

    private func recordAudit(
        clientName: String,
        method: String,
        target: String,
        argsSummary: String,
        argsJSON: String,
        outcome: AuditOutcome,
        since start: ContinuousClock.Instant,
        detail: String,
        resultPreview: String,
        responseBytes: Int
    ) async {
        await auditLogger.record(AuditEntry(
            clientName: clientName,
            method: method,
            toolName: target,
            argumentsSummary: argsSummary,
            argumentsJSON: argsJSON,
            outcome: outcome,
            durationMs: elapsedMs(since: start),
            detail: detail,
            resultPreview: resultPreview,
            responseBytes: responseBytes
        ))
    }

    private func decodeParams<T: Decodable>(_ value: JSONValue, as type: T.Type) throws -> T {
        let data = try encoder.encode(value)
        return try decoder.decode(type, from: data)
    }

    private func encodeDirectSuccess<Result: Encodable & Sendable>(id: JSONRPCID, result: Result) -> Data? {
        do {
            return try JSONRPCCodec.encodeResponseLine(id: id, result: result, using: encoder)
        } catch {
            return encodeDirectError(id: id, error: .internalError(error.localizedDescription))
        }
    }

    private func encodeDirectError(id: JSONRPCID, error: JSONRPCError) -> Data? {
        try? JSONRPCCodec.encodeErrorLine(id: id, error: error, using: encoder)
    }

    private func compactJSONString(_ value: JSONValue) -> String {
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private func elapsedMs(since start: ContinuousClock.Instant) -> Int {
        let duration = start.duration(to: .now)
        let ms = Double(duration.components.seconds) * 1000.0
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000.0
        return max(0, Int(ms.rounded()))
    }
}
