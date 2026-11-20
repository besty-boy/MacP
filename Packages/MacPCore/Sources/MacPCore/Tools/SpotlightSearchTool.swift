import Foundation

/// Native macOS Spotlight file search powered by `/usr/bin/mdfind`.
public struct SpotlightSearchTool: MCPTool {
    public let name = "macos_spotlight_search"
    public let displayName = "Spotlight"
    public let shortSubtitle = "Recherche de fichiers"
    public let symbolName = "magnifyingglass"
    public let category: ToolCategory = .productivity
    public let description = "Searches local macOS files using Spotlight metadata index (mdfind) with optional directory, filename-only mode, and result limit."
    public let sensitivity: ToolSensitivity = .sensitive
    public let permissionReason = "Un client IA souhaite rechercher des fichiers sur votre Mac via Spotlight."

    public let executablePath: String

    public init(executablePath: String = "/usr/bin/mdfind") {
        self.executablePath = executablePath
    }

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: "Recherche Spotlight",
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
                "query": [
                    "type": "string",
                    "description": "Search query text (or filename substring when name_only is true)."
                ],
                "directory": [
                    "type": "string",
                    "description": "Optional directory path to restrict search scope (supports '~')."
                ],
                "name_only": [
                    "type": "boolean",
                    "description": "When true, matches only file names instead of full-text content (default: false)."
                ],
                "limit": [
                    "type": "integer",
                    "description": "Maximum number of paths returned (1 to 100, default: 25).",
                    "minimum": 1,
                    "maximum": 100
                ]
            ],
            "required": ["query"],
            "additionalProperties": false
        ]
    }

    public struct SpotlightMatch: Sendable, Codable {
        public let path: String
        public let fileName: String
        public let isDirectory: Bool
        public let sizeBytes: Int?
        public let modifiedAt: String?
    }

    private struct SearchPayload: Codable {
        let query: String
        let directory: String?
        let totalFound: Int
        let returned: Int
        let matches: [SpotlightMatch]
    }

    public func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        guard let query = arguments["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            return .failure("Paramètre requis manquant : 'query' (String).")
        }

        let nameOnly = arguments["name_only"]?.boolValue ?? false
        let limit = min(max(arguments["limit"]?.intValue ?? 25, 1), 100)

        var resolvedDir: String?
        if let rawDir = arguments["directory"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawDir.isEmpty {
            let expanded = (rawDir as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                return .failure("Dossier introuvable : '\(rawDir)'.")
            }
            resolvedDir = expanded
        }

        var cliArgs: [String] = []
        if let resolvedDir {
            cliArgs.append(contentsOf: ["-onlyin", resolvedDir])
        }
        if nameOnly {
            cliArgs.append(contentsOf: ["-name", query])
        } else {
            cliArgs.append(query)
        }

        let result = try await NativeProcessRunner.run(
            executablePath: executablePath,
            arguments: cliArgs,
            timeoutSeconds: 15
        )

        if result.timedOut {
            return .failure("La recherche Spotlight a dépassé le délai de 15s.")
        }
        if result.exitCode != 0 {
            return .failure("Erreur Spotlight (code \(result.exitCode)) : \(result.stderr)")
        }

        let allPaths = result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }

        let iso = ISO8601DateFormatter()
        let matches: [SpotlightMatch] = allPaths.prefix(limit).map { path in
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return SpotlightMatch(
                path: path,
                fileName: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                sizeBytes: values?.fileSize,
                modifiedAt: values?.contentModificationDate.map { iso.string(from: $0) }
            )
        }

        let payload = SearchPayload(
            query: query,
            directory: resolvedDir,
            totalFound: allPaths.count,
            returned: matches.count,
            matches: matches
        )
        return .success(try ToolOutputFormatter.encodeJSON(payload))
    }
}
