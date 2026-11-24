import AppKit
import Foundation

/// Reads the current plain-text content of the macOS system clipboard (`NSPasteboard.general`).
public struct ClipboardTool: MCPTool {
    public let name = "macos_read_clipboard"
    public let displayName = "Lire Presse-papiers"
    public let shortSubtitle = "Contenu texte copié"
    public let symbolName = "doc.on.clipboard"
    public let category: ToolCategory = .productivity
    public let description = "Reads plain text from the macOS clipboard (NSPasteboard.general)."
    public let sensitivity: ToolSensitivity = .sensitive
    public let permissionReason = "Un client IA souhaite lire le contenu actuel de votre presse-papiers macOS."

    public init() {}

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Lire le Presse-papiers",
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
                "max_length": [
                    "type": "integer",
                    "description": "Max characters (default: 16000, max: 200000).",
                    "minimum": 1,
                    "maximum": 200000
                ]
            ],
            "additionalProperties": false
        ]
    }

    private struct ClipboardPayload: Codable {
        let hasText: Bool
        let characterCount: Int
        let truncated: Bool
        let availableTypesCount: Int
        let text: String?
    }

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        let requestedMax = arguments["max_length"]?.intValue ?? 16_000
        let maxLength = min(max(requestedMax, 1), 200_000)

        let snapshot: (text: String?, typesCount: Int) = await MainActor.run {
            let pasteboard = NSPasteboard.general
            let text = pasteboard.string(forType: .string)
            let typesCount = pasteboard.types?.count ?? 0
            return (text, typesCount)
        }

        guard let fullText = snapshot.text else {
            let payload = ClipboardPayload(
                hasText: false,
                characterCount: 0,
                truncated: false,
                availableTypesCount: snapshot.typesCount,
                text: nil
            )
            return .success(try ToolOutputFormatter.encodeJSON(payload))
        }

        let totalCount = fullText.count
        let truncated = totalCount > maxLength
        let returnedText = truncated ? String(fullText.prefix(maxLength)) : fullText

        let payload = ClipboardPayload(
            hasText: true,
            characterCount: totalCount,
            truncated: truncated,
            availableTypesCount: snapshot.typesCount,
            text: returnedText
        )

        return .success(try ToolOutputFormatter.encodeJSON(payload))
    }
}

/// Writes UTF-8 text to the macOS general clipboard (`NSPasteboard.general`).
public struct WriteClipboardTool: MCPTool {
    public let name = "macos_write_clipboard"
    public let displayName = "Écrire Presse-papiers"
    public let shortSubtitle = "Copier du texte"
    public let symbolName = "clipboard.fill"
    public let category: ToolCategory = .productivity
    public let description = "Copies UTF-8 text to the macOS clipboard."
    public let sensitivity: ToolSensitivity = .sensitive
    public let permissionReason = "Un client IA souhaite remplacer le contenu de votre presse-papiers macOS."

    public init() {}

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Écrire dans le Presse-papiers",
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
                "text": [
                    "type": "string",
                    "description": "UTF-8 text to copy."
                ]
            ],
            "required": ["text"],
            "additionalProperties": false
        ]
    }

    private struct WritePayload: Codable {
        let copied: Bool
        let characterCount: Int
    }

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        guard let text = arguments["text"]?.stringValue else {
            return .failure("Paramètre requis manquant : 'text' (String).")
        }

        let success: Bool = await MainActor.run {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)
        }

        let payload = WritePayload(copied: success, characterCount: text.count)
        let json = try ToolOutputFormatter.encodeJSON(payload)
        return success ? .success(json) : .failure("Impossible d'écrire dans le presse-papiers.")
    }
}
