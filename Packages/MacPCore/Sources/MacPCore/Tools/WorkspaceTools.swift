import AppKit
import Foundation

/// Lists running macOS user applications and identifies the active frontmost app via `NSWorkspace`.
public struct RunningAppsTool: MCPTool {
    public let name = "macos_list_running_apps"
    public let displayName = "Apps Ouvertes"
    public let shortSubtitle = "Applications & fenêtre active"
    public let symbolName = "macwindow.on.rectangle"
    public let category: ToolCategory = .workspace
    public let description = "Lists running macOS apps and the active frontmost app via NSWorkspace."
    public let sensitivity: ToolSensitivity = .standard
    public let permissionReason = "Lecture seule de la liste des applications en cours d'exécution."

    public init() {}

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Lister les applications ouvertes",
            readOnlyHint: true,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    }

    public var inputSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "include_background": [
                    "type": "boolean",
                    "description": "Include menu-bar/accessory apps (default: false)."
                ],
                "include_paths": [
                    "type": "boolean",
                    "description": "Include .app filesystem paths (default: false to save tokens)."
                ]
            ],
            "additionalProperties": false
        ]
    }

    public struct AppInfoDTO: Sendable, Codable {
        public let name: String
        public let bundleIdentifier: String?
        public let pid: Int32
        public let isActive: Bool
        public let isHidden: Bool
        public let bundlePath: String?
    }

    private struct RunningAppsPayload: Codable {
        let frontmostApp: String?
        let frontmostBundleId: String?
        let count: Int
        let applications: [AppInfoDTO]
    }

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        let includeBackground = arguments["include_background"]?.boolValue ?? false
        let includePaths = arguments["include_paths"]?.boolValue ?? false

        let payload: RunningAppsPayload = await MainActor.run {
            let workspace = NSWorkspace.shared
            let apps = workspace.runningApplications
                .filter { app in
                    if includeBackground {
                        return app.activationPolicy == .regular || app.activationPolicy == .accessory
                    }
                    return app.activationPolicy == .regular
                }
                .map { app in
                    AppInfoDTO(
                        name: app.localizedName ?? "Unknown",
                        bundleIdentifier: app.bundleIdentifier,
                        pid: app.processIdentifier,
                        isActive: app.isActive,
                        isHidden: app.isHidden,
                        bundlePath: includePaths ? app.bundleURL?.path : nil
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            let front = workspace.frontmostApplication
            return RunningAppsPayload(
                frontmostApp: front?.localizedName,
                frontmostBundleId: front?.bundleIdentifier,
                count: apps.count,
                applications: apps
            )
        }

        return .success(try ToolOutputFormatter.encodeJSON(payload))
    }
}

/// Opens a macOS application, file path, or URL via `NSWorkspace.shared`.
public struct OpenAppOrURLTool: MCPTool {
    public let name = "macos_open_app_or_url"
    public let displayName = "Ouvrir App / URL"
    public let shortSubtitle = "Lancer app, fichier ou lien"
    public let symbolName = "arrow.up.forward.app"
    public let category: ToolCategory = .workspace
    public let description = "Opens/activates a macOS app (by name or bundle ID), a local file/folder, or a safe URL."
    public let sensitivity: ToolSensitivity = .sensitive
    public let permissionReason = "Un client IA souhaite ouvrir une application, un fichier ou un lien sur votre Mac."

    public init() {}

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Ouvrir une application ou URL",
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: true
        )
    }

    public var inputSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "app_name": [
                    "type": "string",
                    "description": "App name (e.g. 'Safari') or bundle ID (e.g. 'com.apple.Safari')."
                ],
                "url": [
                    "type": "string",
                    "description": "URL to open (e.g. 'https://apple.com')."
                ],
                "file_path": [
                    "type": "string",
                    "description": "Local file or folder path (supports '~')."
                ]
            ],
            "additionalProperties": false
        ]
    }

    private struct OpenPayload: Codable {
        let opened: Bool
        let target: String
        let kind: String
    }

    private static let blockedURLSchemes: Set<String> = [
        "file", "javascript", "data", "vbscript", "blob", "about"
    ]

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        if let rawURL = arguments["url"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawURL.isEmpty {
            guard let url = URL(string: rawURL), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
                return .failure("URL invalide : '\(rawURL)'.")
            }
            guard !Self.blockedURLSchemes.contains(scheme) else {
                return .failure("Schéma d'URL interdit par sécurité : '\(scheme)'.")
            }
            let opened = await MainActor.run { NSWorkspace.shared.open(url) }
            let payload = OpenPayload(opened: opened, target: rawURL, kind: "url")
            let json = try ToolOutputFormatter.encodeJSON(payload)
            return opened ? .success(json) : .failure("Impossible d'ouvrir l'URL '\(rawURL)'.")
        }

        if let rawPath = arguments["file_path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPath.isEmpty {
            guard !rawPath.contains("\0") else {
                return .failure("Chemin de fichier invalide.")
            }
            let expanded = (rawPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded) else {
                return .failure("Fichier ou dossier introuvable : '\(rawPath)'.")
            }
            let fileURL = URL(fileURLWithPath: expanded)
            let opened = await MainActor.run { NSWorkspace.shared.open(fileURL) }
            let payload = OpenPayload(opened: opened, target: expanded, kind: "file")
            let json = try ToolOutputFormatter.encodeJSON(payload)
            return opened ? .success(json) : .failure("Impossible d'ouvrir '\(expanded)'.")
        }

        if let appName = arguments["app_name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !appName.isEmpty {
            guard !appName.contains("\0") else {
                return .failure("Nom d'application invalide.")
            }
            let resolvedURL: URL? = await MainActor.run {
                if let byBundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appName) {
                    return byBundle
                }
                let normalized = appName.hasSuffix(".app") ? appName : "\(appName).app"
                let searchDirs = [
                    "/Applications",
                    "/System/Applications",
                    "/System/Applications/Utilities",
                    (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
                ]
                for dir in searchDirs {
                    let candidate = URL(fileURLWithPath: dir).appendingPathComponent(normalized)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
                return nil
            }

            if let appURL = resolvedURL {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
                let payload = OpenPayload(opened: true, target: appURL.path, kind: "application")
                return .success(try ToolOutputFormatter.encodeJSON(payload))
            }

            let res = try await NativeProcessRunner.run(
                executablePath: "/usr/bin/open",
                arguments: ["-a", appName],
                timeoutSeconds: 10
            )
            if res.exitCode != 0 {
                return .failure("Application introuvable ou impossible à lancer : '\(appName)' (\(res.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))")
            }
            let payload = OpenPayload(opened: true, target: appName, kind: "application")
            return .success(try ToolOutputFormatter.encodeJSON(payload))
        }

        return .failure("Fournissez l'un des paramètres suivants : 'app_name', 'url' ou 'file_path'.")
    }
}

/// Native macOS system controls: instant CoreAudio volume/mute (<1ms, zero subprocesses) and Dark Mode appearance.
public struct SystemControlsTool: MCPTool {
    public let name = "macos_system_controls"
    public let displayName = "Contrôles Mac"
    public let shortSubtitle = "Volume, Muet & Dark Mode"
    public let symbolName = "slider.horizontal.3"
    public let category: ToolCategory = .workspace
    public let description = "Gets or sets macOS output volume (0-100), mute state, and Dark Mode."
    public let sensitivity: ToolSensitivity = .sensitive
    public let permissionReason = "Un client IA souhaite lire ou modifier les réglages système (volume audio ou mode sombre) de votre Mac."

    public init() {}

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Contrôles système macOS",
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    }

    public var inputSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "action": [
                    "type": "string",
                    "description": "'get_state', 'set_volume', 'set_mute', or 'set_dark_mode'.",
                    "enum": ["get_state", "set_volume", "set_mute", "set_dark_mode"]
                ],
                "volume": [
                    "type": "integer",
                    "description": "Output volume 0-100 (for 'set_volume').",
                    "minimum": 0,
                    "maximum": 100
                ],
                "muted": [
                    "type": "boolean",
                    "description": "Mute state (for 'set_mute')."
                ],
                "dark_mode": [
                    "type": "boolean",
                    "description": "Enable/disable Dark Mode (for 'set_dark_mode')."
                ]
            ],
            "required": ["action"],
            "additionalProperties": false
        ]
    }

    private struct ControlsStatePayload: Codable {
        let action: String
        let outputVolume: Int?
        let outputMuted: Bool?
        let darkMode: Bool
    }

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        guard let action = arguments["action"]?.stringValue else {
            return .failure("Paramètre requis manquant : 'action'.")
        }

        switch action {
        case "get_state":
            break

        case "set_volume":
            guard let vol = arguments["volume"]?.intValue, (0...100).contains(vol) else {
                return .failure("Paramètre 'volume' requis (entier entre 0 et 100).")
            }
            if !CoreAudioVolume.setVolume(percent: vol) {
                let res = try await NativeProcessRunner.run(
                    executablePath: "/usr/bin/osascript",
                    arguments: ["-e", "set volume output volume \(vol)"],
                    timeoutSeconds: 8
                )
                if res.exitCode != 0 {
                    return .failure("Impossible de régler le volume : \(res.stderr)")
                }
            }

        case "set_mute":
            guard let muted = arguments["muted"]?.boolValue else {
                return .failure("Paramètre 'muted' requis (booléen).")
            }
            if !CoreAudioVolume.setMuted(muted) {
                let res = try await NativeProcessRunner.run(
                    executablePath: "/usr/bin/osascript",
                    arguments: ["-e", "set volume output muted \(muted ? "true" : "false")"],
                    timeoutSeconds: 8
                )
                if res.exitCode != 0 {
                    return .failure("Impossible de modifier le mode muet : \(res.stderr)")
                }
            }

        case "set_dark_mode":
            guard let darkMode = arguments["dark_mode"]?.boolValue else {
                return .failure("Paramètre 'dark_mode' requis (booléen).")
            }
            let script = """
            tell application "System Events"
                tell appearance preferences
                    set dark mode to \(darkMode ? "true" : "false")
                end tell
            end tell
            """
            let res = try await NativeProcessRunner.run(
                executablePath: "/usr/bin/osascript",
                arguments: ["-e", script],
                timeoutSeconds: 10
            )
            if res.exitCode != 0 {
                return .failure("Impossible de changer l'apparence (vérifiez Automation > System Events) : \(res.stderr)")
            }

        default:
            return .failure("Action inconnue : '\(action)'. Actions valides : get_state, set_volume, set_mute, set_dark_mode.")
        }

        let audioState = await readAudioSettings()
        let isDark = SystemStatsTool.isDarkModeEnabled()
        let payload = ControlsStatePayload(
            action: action,
            outputVolume: audioState.volume,
            outputMuted: audioState.muted,
            darkMode: isDark
        )
        return .success(try ToolOutputFormatter.encodeJSON(payload))
    }

    private func readAudioSettings() async -> (volume: Int?, muted: Bool?) {
        // Fast path: direct CoreAudio HAL read (< 1ms, 0 subprocesses).
        if let native = CoreAudioVolume.readState() {
            return (native.volume, native.muted)
        }

        // Fallback for virtual audio devices lacking standard CoreAudio volume properties.
        let script = """
        set v to get volume settings
        return (output volume of v as string) & "," & (output muted of v as string)
        """
        guard let res = try? await NativeProcessRunner.run(
            executablePath: "/usr/bin/osascript",
            arguments: ["-e", script],
            timeoutSeconds: 6
        ), res.exitCode == 0 else {
            return (nil, nil)
        }
        let parts = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
        guard parts.count == 2 else { return (nil, nil) }
        return (Int(parts[0]), parts[1].lowercased() == "true")
    }
}
