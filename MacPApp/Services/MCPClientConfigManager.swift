import Foundation

/// Supported AI desktop & CLI clients that MacP can detect and configure in 1 click.
enum SupportedMCPClient: String, CaseIterable, Identifiable, Sendable {
    case antigravity
    case claudeDesktop
    case claudeCode
    case cursor
    case windsurf

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .antigravity: return "Antigravity"
        case .claudeDesktop: return "Claude Desktop"
        case .claudeCode: return "Claude Code"
        case .cursor: return "Cursor"
        case .windsurf: return "Windsurf"
        }
    }

    var symbolName: String {
        switch self {
        case .antigravity: return "sparkles"
        case .claudeDesktop: return "bubble.left.and.text.bubble.right"
        case .claudeCode: return "terminal"
        case .cursor: return "cursorarrow.rays"
        case .windsurf: return "wind"
        }
    }

    var configFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .antigravity:
            return home.appendingPathComponent(".gemini/config/mcp_config.json")
        case .claudeDesktop:
            return home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        case .claudeCode:
            return home.appendingPathComponent(".claude.json")
        case .cursor:
            return home.appendingPathComponent(".cursor/mcp.json")
        case .windsurf:
            return home.appendingPathComponent(".codeium/windsurf/mcp_config.json")
        }
    }

    /// Lightweight heuristic to detect whether the client is installed or previously used on this Mac.
    var isLikelyInstalled: Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: configFileURL.path) {
            return true
        }
        let parentDir = configFileURL.deletingLastPathComponent().path
        switch self {
        case .antigravity:
            return fm.fileExists(atPath: parentDir) || fm.fileExists(atPath: "/Applications/Antigravity.app")
        case .claudeDesktop:
            return fm.fileExists(atPath: "/Applications/Claude.app") || fm.fileExists(atPath: parentDir)
        case .claudeCode:
            return fm.fileExists(atPath: fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path)
        case .cursor:
            return fm.fileExists(atPath: "/Applications/Cursor.app") || fm.fileExists(atPath: parentDir)
        case .windsurf:
            return fm.fileExists(atPath: "/Applications/Windsurf.app") || fm.fileExists(atPath: parentDir)
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
        case .error: return "JSON invalide"
        }
    }
}

enum ClientConfigError: LocalizedError {
    case malformedExistingJSON(URL)

    var errorDescription: String? {
        switch self {
        case let .malformedExistingJSON(url):
            return "Le fichier existant (\(url.lastPathComponent)) contient du JSON invalide et n'a pas été écrasé par sécurité."
        }
    }
}

/// Safely reads and updates MCP JSON configuration files for supported AI clients
/// without disturbing other configured MCP servers or overwriting corrupted files.
enum MCPClientConfigManager {
    static var currentExecutablePath: String {
        Bundle.main.executablePath ?? "/Applications/MacP.app/Contents/MacOS/MacP"
    }

    static func status(for client: SupportedMCPClient, targetCommand: String = currentExecutablePath) -> ClientConfigStatus {
        let url = client.configFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .notConfigured
        }

        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { return .notConfigured }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .error("Racine JSON non-objet")
            }
            guard let servers = root["mcpServers"] as? [String: Any],
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
            if !existingData.isEmpty {
                guard let existingObj = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
                    throw ClientConfigError.malformedExistingJSON(url)
                }
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
        guard !existingData.isEmpty else { return }
        guard var root = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else {
            throw ClientConfigError.malformedExistingJSON(url)
        }
        guard var servers = root["mcpServers"] as? [String: Any] else {
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
