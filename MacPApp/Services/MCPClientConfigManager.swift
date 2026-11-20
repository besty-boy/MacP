import Foundation

/// Supported AI desktop clients that MacP can detect and configure in 1 click.
enum SupportedMCPClient: String, CaseIterable, Identifiable, Sendable {
    case antigravity
    case claudeDesktop
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .claudeDesktop: return "Claude Desktop"
        case .cursor: return "Cursor"
        }
    }

    var symbolName: String {
        switch self {
        case .antigravity: return "sparkles"
        case .claudeDesktop: return "bubble.left.and.text.bubble.right"
        case .cursor: return "cursorarrow.rays"
        }
    }

    var configFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .antigravity:
            return home.appendingPathComponent(".gemini/config/mcp_config.json")
        case .claudeDesktop:
            return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .cursor:
            return home.appendingPathComponent(".cursor/mcp.json")
        }
    }
}

enum ClientConfigStatus: Equatable, Sendable {
    case configured
    case outdatedPath(existingCommand: String)
    case notConfigured
    case error(String)

    var label: String {
        switch self {
        case .configured: return "Configuré"
        case .outdatedPath: return "Chemin différent"
        case .notConfigured: return "Non configuré"
        case .error: return "Erreur"
        }
    }
}

/// Safely reads and updates MCP JSON configuration files for Antigravity, Claude Desktop, and Cursor
/// without disturbing any other configured MCP servers.
enum MCPClientConfigManager {
    static var currentExecutablePath: String {
        let bundleExec = Bundle.main.executablePath ?? "/Applications/MacP.app/Contents/MacOS/MacP"
        return bundleExec
    }

    static func status(for client: SupportedMCPClient, targetCommand: String = currentExecutablePath) -> ClientConfigStatus {
        let url = client.configFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .notConfigured
        }

        do {
            let data = try Data(contentsOf: url)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = root["mcpServers"] as? [String: Any],
                  let macp = servers["macp"] as? [String: Any],
                  let cmd = macp["command"] as? String else {
                return .notConfigured
            }
            let args = macp["args"] as? [String] ?? []
            if cmd == targetCommand && args == ["--stdio"] {
                return .configured
            }
            return .outdatedPath(existingCommand: cmd)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    static func installOrUpdate(client: SupportedMCPClient, targetCommand: String = currentExecutablePath) throws {
        let url = client.configFileURL
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let existingData = try Data(contentsOf: url)
            if !existingData.isEmpty,
               let existingObj = try JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
                root = existingObj
            }
        }

        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers["macp"] = [
            "command": targetCommand,
            "args": ["--stdio"]
        ]
        root["mcpServers"] = servers

        let encoded = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try encoded.write(to: url, options: .atomic)
    }

    static func remove(client: SupportedMCPClient) throws {
        let url = client.configFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let existingData = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: existingData) as? [String: Any],
              var servers = root["mcpServers"] as? [String: Any] else {
            return
        }
        servers.removeValue(forKey: "macp")
        root["mcpServers"] = servers

        let encoded = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try encoded.write(to: url, options: .atomic)
    }
}
