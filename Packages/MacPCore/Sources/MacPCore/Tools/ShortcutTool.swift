import Foundation

/// Lists available macOS Shortcuts via `/usr/bin/shortcuts list`.
public struct ListShortcutsTool: MCPTool {
    public let name = "macos_list_shortcuts"
    public let displayName = "Lister Raccourcis"
    public let shortSubtitle = "Découvrir les Raccourcis"
    public let symbolName = "list.bullet.rectangle"
    public let category: ToolCategory = .productivity
    public let description = "Lists installed macOS Shortcuts (optionally filtered by folder)."
    public let sensitivity: ToolSensitivity = .standard
    public let permissionReason = "Lecture seule des noms de Raccourcis disponibles sur ce Mac."

    public let executablePath: String
    public let timeoutSeconds: TimeInterval

    public init(
        executablePath: String = "/usr/bin/shortcuts",
        timeoutSeconds: TimeInterval = 15
    ) {
        self.executablePath = executablePath
        self.timeoutSeconds = timeoutSeconds
    }

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Lister les Raccourcis macOS",
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
                "folder": [
                    "type": "string",
                    "description": "Optional Shortcuts folder filter."
                ]
            ],
            "additionalProperties": false
        ]
    }

    private struct ListPayload: Codable {
        let count: Int
        let folder: String?
        let shortcuts: [String]
    }

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return .failure("Exécutable introuvable : \(executablePath)")
        }

        let folder = arguments["folder"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        var cliArgs = ["list"]
        if let folder, !folder.isEmpty {
            cliArgs.append(contentsOf: ["--folder-name", folder])
        }

        let result = try await NativeProcessRunner.run(
            executablePath: executablePath,
            arguments: cliArgs,
            timeoutSeconds: timeoutSeconds
        )

        if result.timedOut {
            return .failure("La commande 'shortcuts list' a dépassé le délai de \(Int(timeoutSeconds))s.")
        }
        if result.exitCode != 0 {
            return .failure("Erreur shortcuts list (code \(result.exitCode)) : \(result.stderr)")
        }

        let names = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let payload = ListPayload(
            count: names.count,
            folder: (folder?.isEmpty == false) ? folder : nil,
            shortcuts: names
        )
        return .success(try ToolOutputFormatter.encodeJSON(payload))
    }
}

/// Executes an existing macOS Shortcut via `/usr/bin/shortcuts run <shortcut_name>`.
public struct ShortcutTool: MCPTool {
    public let name = "macos_run_shortcut"
    public let displayName = "Exécuter Raccourci"
    public let shortSubtitle = "Lancer un Raccourci macOS"
    public let symbolName = "square.2.layers.3d.top.filled"
    public let category: ToolCategory = .productivity
    public let description = "Runs a macOS Shortcut by name and returns its stdout/stderr."
    public let sensitivity: ToolSensitivity = .sensitive
    public let permissionReason = "Un client IA souhaite exécuter un Raccourci macOS pouvant déclencher des automatisations système ou modifier des fichiers."

    public let executablePath: String
    public let timeoutSeconds: TimeInterval

    public init(
        executablePath: String = "/usr/bin/shortcuts",
        timeoutSeconds: TimeInterval = 30
    ) {
        self.executablePath = executablePath
        self.timeoutSeconds = timeoutSeconds
    }

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Exécuter un Raccourci macOS",
            readOnlyHint: false,
            destructiveHint: true,
            idempotentHint: false,
            openWorldHint: true
        )
    }

    public var inputSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "shortcut_name": [
                    "type": "string",
                    "description": "Exact macOS Shortcut name."
                ],
                "input_text": [
                    "type": "string",
                    "description": "Optional stdin text."
                ]
            ],
            "required": ["shortcut_name"],
            "additionalProperties": false
        ]
    }

    private struct OutputPayload: Codable {
        let shortcut: String
        let exitCode: Int32
        let output: String
        let errorOutput: String
    }

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        guard let rawName = arguments["shortcut_name"]?.stringValue else {
            return .failure("Paramètre requis manquant : 'shortcut_name' (String).")
        }

        let shortcutName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !shortcutName.isEmpty else {
            return .failure("Le paramètre 'shortcut_name' ne peut pas être vide.")
        }

        let inputText = arguments["input_text"]?.stringValue

        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return .failure("Exécutable introuvable : \(executablePath)")
        }

        let result = try await NativeProcessRunner.run(
            executablePath: executablePath,
            arguments: ["run", shortcutName],
            inputText: inputText,
            timeoutSeconds: timeoutSeconds
        )

        if result.timedOut {
            return .failure("Le raccourci '\(shortcutName)' a dépassé le délai maximal de \(Int(timeoutSeconds))s et a été interrompu.")
        }

        let payload = OutputPayload(
            shortcut: shortcutName,
            exitCode: result.exitCode,
            output: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            errorOutput: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let json = try ToolOutputFormatter.encodeJSON(payload)
        if result.exitCode != 0 {
            return .failure(json)
        }
        return .success(json)
    }
}
