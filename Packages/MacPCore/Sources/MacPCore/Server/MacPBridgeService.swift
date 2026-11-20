import Foundation

/// Live state snapshot published by `MacPBridgeService` to the SwiftUI Menu Bar Dashboard.
public struct BridgeSnapshot: Sendable, Equatable {
    public let isListening: Bool
    public let isShieldModeActive: Bool
    public let socketPath: String
    public let connectedClients: [ConnectedClientInfo]
    public let lastError: String?

    public var isClientConnected: Bool {
        !connectedClients.isEmpty
    }

    public init(
        isListening: Bool = false,
        isShieldModeActive: Bool = false,
        socketPath: String = MacPSocketPath.defaultPath,
        connectedClients: [ConnectedClientInfo] = [],
        lastError: String? = nil
    ) {
        self.isListening = isListening
        self.isShieldModeActive = isShieldModeActive
        self.socketPath = socketPath
        self.connectedClients = connectedClients
        self.lastError = lastError
    }
}

/// High-level native macOS MCP bridge daemon managing the local Unix socket, client sessions,
/// tool registry, resources, prompts, permissions, and audit log.
public actor MacPBridgeService {
    public let registry: MCPToolRegistry
    public let resourceCatalog: MCPResourceCatalog
    public let promptCatalog: MCPPromptCatalog
    public let settings: ToolSettingsStore
    public let permissionManager: PermissionManager
    public let auditLogger: AuditLogger
    public let socketPath: String

    private var socketServer: UnixSocketServer?
    private var sessions: [UUID: MCPServerSession] = [:]
    private var clients: [UUID: ConnectedClientInfo] = [:]
    private var isListening = false
    private var lastError: String?
    private var snapshotObservers: [UUID: AsyncStream<BridgeSnapshot>.Continuation] = [:]

    public init(
        registry: MCPToolRegistry = .defaultMacOSTools(),
        resourceCatalog: MCPResourceCatalog = MCPResourceCatalog(),
        promptCatalog: MCPPromptCatalog = MCPPromptCatalog(),
        settings: ToolSettingsStore = ToolSettingsStore(),
        permissionManager: PermissionManager,
        auditLogger: AuditLogger = AuditLogger(),
        socketPath: String = MacPSocketPath.defaultPath
    ) {
        self.registry = registry
        self.resourceCatalog = resourceCatalog
        self.promptCatalog = promptCatalog
        self.settings = settings
        self.permissionManager = permissionManager
        self.auditLogger = auditLogger
        self.socketPath = socketPath
    }

    /// Starts the local Unix socket server so `MacP --stdio` processes can attach.
    public func start() {
        guard !isListening else { return }

        let server = UnixSocketServer(socketPath: socketPath)
        do {
            try server.start { [weak self] clientID, transport in
                await self?.handleClientConnection(clientID: clientID, transport: transport)
            }
            self.socketServer = server
            self.isListening = true
            self.lastError = nil
        } catch {
            self.isListening = false
            self.lastError = error.localizedDescription
            DiagnosticLog.write("Failed to start MacPBridgeService: \(error.localizedDescription)")
        }

        publishSnapshot()
    }

    public func stop() {
        socketServer?.stop()
        socketServer = nil
        isListening = false
        sessions.removeAll()
        clients.removeAll()
        publishSnapshot()
    }

    public func currentSnapshot() -> BridgeSnapshot {
        let sortedClients = clients.values.sorted { $0.connectedAt < $1.connectedAt }
        return BridgeSnapshot(
            isListening: isListening,
            isShieldModeActive: settings.isShieldModeActive,
            socketPath: socketPath,
            connectedClients: sortedClients,
            lastError: lastError
        )
    }

    public func observeSnapshots() -> AsyncStream<BridgeSnapshot> {
        let id = UUID()
        let initial = currentSnapshot()
        return AsyncStream { continuation in
            snapshotObservers[id] = continuation
            continuation.yield(initial)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSnapshotObserver(id: id) }
            }
        }
    }

    /// Notifies all connected MCP clients that tools & resources lists changed (e.g. toggle or Shield Mode).
    public func notifyToolsChanged() async {
        publishSnapshot()
        let activeSessions = Array(sessions.values)
        for session in activeSessions {
            await session.sendToolsListChangedNotification()
            await session.sendResourcesListChangedNotification()
        }
    }

    /// Runs a standalone single-session MCP server directly on `stdio` (used as CLI fallback or `--standalone`).
    public static func runStandaloneStdio(
        registry: MCPToolRegistry = .defaultMacOSTools(),
        settings: ToolSettingsStore = ToolSettingsStore(),
        prompter: any PermissionPrompter = StaticPermissionPrompter(decision: .allowOnce),
        auditLogger: AuditLogger = AuditLogger(),
        transport: any NDJSONTransport = StdioTransport()
    ) async {
        let permissionManager = PermissionManager(settings: settings, prompter: prompter)
        let session = MCPServerSession(
            registry: registry,
            settings: settings,
            permissionManager: permissionManager,
            auditLogger: auditLogger,
            transport: transport
        )
        await session.run()
    }

    // MARK: - Internal Session Tracking

    private func handleClientConnection(clientID: UUID, transport: FileDescriptorTransport) async {
        let initialClient = ConnectedClientInfo(id: clientID)
        clients[clientID] = initialClient

        let session = MCPServerSession(
            sessionID: clientID,
            registry: registry,
            resourceCatalog: resourceCatalog,
            promptCatalog: promptCatalog,
            settings: settings,
            permissionManager: permissionManager,
            auditLogger: auditLogger,
            transport: transport,
            onClientUpdated: { [weak self] updated in
                await self?.updateClientInfo(updated)
            }
        )
        sessions[clientID] = session
        publishSnapshot()

        await session.run()

        sessions.removeValue(forKey: clientID)
        clients.removeValue(forKey: clientID)
        publishSnapshot()
    }

    private func updateClientInfo(_ updated: ConnectedClientInfo) {
        guard clients[updated.id] != nil else { return }
        clients[updated.id] = updated
        publishSnapshot()
    }

    private func publishSnapshot() {
        let snapshot = currentSnapshot()
        for continuation in snapshotObservers.values {
            continuation.yield(snapshot)
        }
    }

    private func removeSnapshotObserver(id: UUID) {
        snapshotObservers.removeValue(forKey: id)
    }
}
