import Foundation

/// Sends a native macOS Notification Center banner safely via `/usr/bin/osascript` argv binding.
public struct NotificationTool: MCPTool {
    public let name = "macos_send_notification"
    public let displayName = "Notification"
    public let shortSubtitle = "Bannière macOS native"
    public let symbolName = "bell.badge"
    public let category: ToolCategory = .productivity
    public let description = "Displays a native macOS notification banner (title, message, optional subtitle/sound)."
    public let sensitivity: ToolSensitivity = .sensitive
    public let permissionReason = "Un client IA souhaite afficher une notification macOS sur votre écran."

    public init() {}

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Envoyer une Notification macOS",
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: false,
            openWorldHint: false
        )
    }

    public var inputSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "title": [
                    "type": "string",
                    "description": "Notification title."
                ],
                "message": [
                    "type": "string",
                    "description": "Notification body text."
                ],
                "subtitle": [
                    "type": "string",
                    "description": "Optional subtitle."
                ],
                "sound": [
                    "type": "string",
                    "description": "Optional system sound (e.g. 'Glass', 'Ping', 'Pop')."
                ]
            ],
            "required": ["title", "message"],
            "additionalProperties": false
        ]
    }

    private struct NotificationPayload: Codable {
        let delivered: Bool
        let title: String
        let message: String
    }

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        guard let title = arguments["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else {
            return .failure("Paramètre requis manquant : 'title' (String).")
        }
        guard let message = arguments["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !message.isEmpty else {
            return .failure("Paramètre requis manquant : 'message' (String).")
        }

        let subtitle = arguments["subtitle"]?.stringValue ?? ""
        let sound = arguments["sound"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Pass all user-supplied text strictly through `argv` to prevent script injection.
        let script: String
        let scriptArgs: [String]
        if sound.isEmpty {
            script = """
            on run argv
                display notification (item 2 of argv) with title (item 1 of argv) subtitle (item 3 of argv)
            end run
            """
            scriptArgs = ["-e", script, "--", title, message, subtitle]
        } else {
            script = """
            on run argv
                display notification (item 2 of argv) with title (item 1 of argv) subtitle (item 3 of argv) sound name (item 4 of argv)
            end run
            """
            scriptArgs = ["-e", script, "--", title, message, subtitle, sound]
        }

        let result = try await NativeProcessRunner.run(
            executablePath: "/usr/bin/osascript",
            arguments: scriptArgs,
            timeoutSeconds: 10
        )

        if result.exitCode != 0 {
            return .failure("Échec de l'envoi de la notification : \(result.stderr)")
        }

        let payload = NotificationPayload(delivered: true, title: title, message: message)
        return .success(try ToolOutputFormatter.encodeJSON(payload))
    }
}
