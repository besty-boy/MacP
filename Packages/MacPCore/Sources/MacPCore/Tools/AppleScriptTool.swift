import Foundation

/// Executes AppleScript or JXA (JavaScript for Automation) scripts via `/usr/bin/osascript`
/// under strict per-call user approval (`critical` / `alwaysAsk` default policy).
public struct AppleScriptTool: MCPTool {
    public let name = "macos_run_applescript"
    public let displayName = "AppleScript / JXA"
    public let shortSubtitle = "Automatisation avancée"
    public let symbolName = "applescript"
    public let category: ToolCategory = .automation
    public let description = "Executes a native macOS AppleScript or JavaScript for Automation (JXA) script via /usr/bin/osascript to automate apps like Finder, Safari, Notes, Mail, or Music. Always requires explicit user approval by default."
    public let sensitivity: ToolSensitivity = .critical
    public let permissionReason = "Un client IA souhaite exécuter un script AppleScript/JXA sur votre Mac. Vérifiez soigneusement le script avant d'autoriser."

    public let executablePath: String

    public init(executablePath: String = "/usr/bin/osascript") {
        self.executablePath = executablePath
    }

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Exécuter AppleScript / JXA",
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
                "script": [
                    "type": "string",
                    "description": "AppleScript or JXA source code to execute."
                ],
                "language": [
                    "type": "string",
                    "description": "Script language: 'AppleScript' (default) or 'JavaScript' (JXA).",
                    "enum": ["AppleScript", "JavaScript"]
                ],
                "timeout_seconds": [
                    "type": "integer",
                    "description": "Execution timeout in seconds (1 to 60, default: 20).",
                    "minimum": 1,
                    "maximum": 60
                ]
            ],
            "required": ["script"],
            "additionalProperties": false
        ]
    }

    private struct ScriptOutputPayload: Codable {
        let language: String
        let exitCode: Int32
        let output: String
        let errorOutput: String
    }

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        guard let script = arguments["script"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty else {
            return .failure("Paramètre requis manquant : 'script' (String).")
        }

        let requestedLang = arguments["language"]?.stringValue ?? "AppleScript"
        let language = (requestedLang == "JavaScript") ? "JavaScript" : "AppleScript"
        let timeout = TimeInterval(min(max(arguments["timeout_seconds"]?.intValue ?? 20, 1), 60))

        let result = try await NativeProcessRunner.run(
            executablePath: executablePath,
            arguments: ["-l", language, "-"],
            inputText: script,
            timeoutSeconds: timeout
        )

        if result.timedOut {
            return .failure("Le script \(language) a dépassé le délai maximal de \(Int(timeout))s et a été arrêté.")
        }

        let payload = ScriptOutputPayload(
            language: language,
            exitCode: result.exitCode,
            output: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            errorOutput: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let json = try ToolOutputFormatter.encodeJSON(payload)
        return result.exitCode == 0 ? .success(json) : .failure(json)
    }
}
