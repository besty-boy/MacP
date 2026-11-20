import AppKit
import Foundation
import MacPCore
import Observation
import UniformTypeIdentifiers

/// Central `@MainActor` observable view model powering MacP V2 Dashboard, Tools, Clients, and Audit Inspector.
@MainActor
@Observable
final class AppState {
    let registry: MCPToolRegistry
    let settings: ToolSettingsStore
    let auditLogger: AuditLogger
    let permissionManager: PermissionManager
    let bridgeService: MacPBridgeService

    private(set) var snapshot: BridgeSnapshot = BridgeSnapshot()
    private(set) var liveTelemetry: SystemStatsTool.SystemStatsPayload?
    private(set) var isShieldModeActive: Bool = false
    private(set) var toolEnabledStates: [String: Bool] = [:]
    private(set) var toolAlwaysAllowedStates: [String: Bool] = [:]
    private(set) var toolPolicies: [String: ToolPermissionPolicy] = [:]
    private(set) var temporaryGrants: [String: Date] = [:]
    private(set) var recentEntries: [AuditEntry] = []
    private(set) var allEntries: [AuditEntry] = []
    private(set) var clientStatuses: [SupportedMCPClient: ClientConfigStatus] = [:]
    private(set) var launchAtLoginEnabled: Bool = false
    private(set) var launchAtLoginMessage: String?
    private(set) var copiedConfigFeedback = false
    private(set) var clientActionBanner: String?

    private var snapshotTask: Task<Void, Never>?
    private var auditTask: Task<Void, Never>?
    private var telemetryTask: Task<Void, Never>?
    private var copyResetTask: Task<Void, Never>?
    private var bannerResetTask: Task<Void, Never>?
    private var hasStarted = false

    init() {
        let registry = MCPToolRegistry.defaultMacOSTools()
        let settings = ToolSettingsStore()
        let auditLogger = AuditLogger()
        let permissionManager = PermissionManager(
            settings: settings,
            prompter: NativePermissionPrompter()
        )
        let bridgeService = MacPBridgeService(
            registry: registry,
            settings: settings,
            permissionManager: permissionManager,
            auditLogger: auditLogger
        )

        self.registry = registry
        self.settings = settings
        self.auditLogger = auditLogger
        self.permissionManager = permissionManager
        self.bridgeService = bridgeService
        self.isShieldModeActive = settings.isShieldModeActive

        refreshToolStates()
        refreshClientStatuses()
        refreshLaunchAtLogin()
    }

    var tools: [MCPToolMetadata] {
        registry.allMetadata
    }

    var activeToolsCount: Int {
        guard !isShieldModeActive else { return 0 }
        return tools.filter { isToolEnabled($0.name) }.count
    }

    var activeGrantsCount: Int {
        let permanent = tools.filter { isAlwaysAllowed($0.name) }.count
        return permanent + temporaryGrants.count
    }

    // MARK: - Lifecycle

    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        Task {
            await bridgeService.start()
            let initialEntries = await auditLogger.allLoadedEntries()
            self.allEntries = initialEntries
            self.recentEntries = Array(initialEntries.prefix(5))
            await self.refreshTemporaryGrants()
        }

        snapshotTask = Task { [weak self] in
            guard let self else { return }
            let stream = await bridgeService.observeSnapshots()
            for await nextSnapshot in stream {
                if Task.isCancelled { break }
                self.snapshot = nextSnapshot
            }
        }

        auditTask = Task { [weak self] in
            guard let self else { return }
            let stream = await auditLogger.subscribe()
            for await newEntry in stream {
                if Task.isCancelled { break }
                self.allEntries.insert(newEntry, at: 0)
                if self.allEntries.count > 500 {
                    self.allEntries.removeLast(self.allEntries.count - 500)
                }
                self.recentEntries = Array(self.allEntries.prefix(5))
                self.refreshToolStates()
                await self.refreshTemporaryGrants()
            }
        }
    }

    func stop() {
        snapshotTask?.cancel()
        auditTask?.cancel()
        telemetryTask?.cancel()
        copyResetTask?.cancel()
        bannerResetTask?.cancel()
        let service = bridgeService
        Task {
            await service.stop()
        }
    }

    /// Starts live CPU/RAM/Battery/Disk polling ONLY while the Menu Bar popover is visible (zero idle battery drain).
    func startLiveTelemetry() {
        telemetryTask?.cancel()
        telemetryTask = Task { [weak self] in
            while !Task.isCancelled {
                let stats = await SystemStatsTool.collectSnapshot()
                guard let self, !Task.isCancelled else { break }
                self.liveTelemetry = stats
                await self.refreshTemporaryGrants()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func stopLiveTelemetry() {
        telemetryTask?.cancel()
        telemetryTask = nil
    }

    // MARK: - Shield Mode & Tool Controls

    func setShieldMode(_ active: Bool) {
        settings.isShieldModeActive = active
        isShieldModeActive = active
        Task {
            await bridgeService.notifyToolsChanged()
        }
    }

    func isToolEnabled(_ toolName: String) -> Bool {
        toolEnabledStates[toolName] ?? settings.isToolEnabled(toolName)
    }

    func setToolEnabled(_ toolName: String, enabled: Bool) {
        settings.setToolEnabled(toolName, enabled: enabled)
        toolEnabledStates[toolName] = enabled
        Task {
            await bridgeService.notifyToolsChanged()
        }
    }

    func policy(for tool: MCPToolMetadata) -> ToolPermissionPolicy {
        toolPolicies[tool.name] ?? settings.permissionPolicy(
            for: tool.name,
            defaultPolicy: tool.sensitivity.defaultPolicy
        )
    }

    func setPolicy(_ policy: ToolPermissionPolicy, for toolName: String) {
        settings.setPermissionPolicy(toolName, policy: policy)
        toolPolicies[toolName] = policy
        if policy == .alwaysAsk {
            toolAlwaysAllowedStates[toolName] = false
            Task {
                await permissionManager.revokeTemporaryGrant(toolName: toolName)
                await refreshTemporaryGrants()
            }
        }
    }

    func isAlwaysAllowed(_ toolName: String) -> Bool {
        toolAlwaysAllowedStates[toolName] ?? settings.isAlwaysAllowed(toolName)
    }

    func remainingLeaseMinutes(for toolName: String) -> Int? {
        guard let expiry = temporaryGrants[toolName] else { return nil }
        let remaining = expiry.timeIntervalSinceNow
        guard remaining > 0 else { return nil }
        return max(1, Int(ceil(remaining / 60.0)))
    }

    func revokePermission(for toolName: String) {
        settings.setAlwaysAllowed(toolName, allowed: false)
        toolAlwaysAllowedStates[toolName] = false
        Task {
            await permissionManager.revokeAlwaysAllowed(toolName: toolName)
            await refreshTemporaryGrants()
        }
    }

    func revokeAllPermissions() {
        let names = tools.map(\.name)
        settings.revokeAllPermissions(for: names)
        refreshToolStates()
        Task {
            await permissionManager.revokeAllGrants(for: names)
            await refreshTemporaryGrants()
        }
    }

    func refreshToolStates() {
        var enabledMap: [String: Bool] = [:]
        var allowedMap: [String: Bool] = [:]
        var policyMap: [String: ToolPermissionPolicy] = [:]
        for tool in tools {
            enabledMap[tool.name] = settings.isToolEnabled(tool.name)
            allowedMap[tool.name] = settings.isAlwaysAllowed(tool.name)
            policyMap[tool.name] = settings.permissionPolicy(
                for: tool.name,
                defaultPolicy: tool.sensitivity.defaultPolicy
            )
        }
        toolEnabledStates = enabledMap
        toolAlwaysAllowedStates = allowedMap
        toolPolicies = policyMap
    }

    private func refreshTemporaryGrants() async {
        temporaryGrants = await permissionManager.activeTemporaryGrants()
    }

    // MARK: - 1-Click MCP Client Config & Launch at Login

    func refreshClientStatuses() {
        var statuses: [SupportedMCPClient: ClientConfigStatus] = [:]
        for client in SupportedMCPClient.allCases {
            statuses[client] = MCPClientConfigManager.status(for: client)
        }
        clientStatuses = statuses
    }

    func configureClient(_ client: SupportedMCPClient) {
        do {
            try MCPClientConfigManager.installOrUpdate(client: client)
            refreshClientStatuses()
            showClientBanner("\(client.displayName) configuré ! Redémarrez le client pour activer MacP.")
        } catch {
            showClientBanner("Erreur \(client.displayName) : \(error.localizedDescription)")
        }
    }

    func removeClientConfig(_ client: SupportedMCPClient) {
        do {
            try MCPClientConfigManager.remove(client: client)
            refreshClientStatuses()
            showClientBanner("MacP retiré de \(client.displayName).")
        } catch {
            showClientBanner("Erreur \(client.displayName) : \(error.localizedDescription)")
        }
    }

    func refreshLaunchAtLogin() {
        launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
        launchAtLoginMessage = LaunchAtLoginManager.statusDescription
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLoginManager.setEnabled(enabled)
            refreshLaunchAtLogin()
        } catch {
            launchAtLoginMessage = "Impossible de modifier l'ouverture automatique : \(error.localizedDescription)"
            launchAtLoginEnabled = LaunchAtLoginManager.isEnabled
        }
    }

    private func showClientBanner(_ message: String) {
        clientActionBanner = message
        bannerResetTask?.cancel()
        bannerResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.clientActionBanner = nil
        }
    }

    // MARK: - Audit & Utilities

    func clearAuditLog() {
        Task {
            await auditLogger.clear()
            self.allEntries.removeAll()
            self.recentEntries.removeAll()
        }
    }

    func exportAuditLog(asCSV: Bool) {
        let panel = NSSavePanel()
        panel.title = asCSV ? "Exporter le journal d'audit (CSV)" : "Exporter le journal d'audit (JSON)"
        panel.nameFieldStringValue = asCSV ? "macp-audit.csv" : "macp-audit.json"
        panel.allowedContentTypes = asCSV ? [.commaSeparatedText] : [.json]

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                if asCSV {
                    let csv = await auditLogger.exportCSV()
                    try csv.write(to: destination, atomically: true, encoding: .utf8)
                } else {
                    let data = try await auditLogger.exportJSON()
                    try data.write(to: destination, options: .atomic)
                }
            } catch {
                DiagnosticLog.write("Audit export failed: \(error.localizedDescription)")
            }
        }
    }

    func revealAuditLogInFinder() {
        let url = auditLogger.logFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let folder = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        }
    }

    func mcpConfigSnippet() -> String {
        let executablePath = MCPClientConfigManager.currentExecutablePath
        return """
        {
          "mcpServers": {
            "macp": {
              "command": "\(executablePath)",
              "args": ["--stdio"]
            }
          }
        }
        """
    }

    func copyMCPConfigToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(mcpConfigSnippet(), forType: .string)

        copiedConfigFeedback = true
        copyResetTask?.cancel()
        copyResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.copiedConfigFeedback = false
        }
    }

    func quitApp() {
        stop()
        NSApp.terminate(nil)
    }
}
