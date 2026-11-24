import Foundation

/// Native macOS Spotlight file search powered by `/usr/bin/mdfind` with bounded streaming output.
public struct SpotlightSearchTool: MCPTool {
    public let name = "macos_spotlight_search"
    public let displayName = "Spotlight"
    public let shortSubtitle = "Recherche de fichiers"
    public let symbolName = "magnifyingglass"
    public let category: ToolCategory = .productivity
    public let description = "Searches local files via macOS Spotlight (mdfind) with optional directory, name-only mode, and limit."
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
                    "description": "Search text (or filename substring if name_only is true)."
                ],
                "directory": [
                    "type": "string",
                    "description": "Optional scope directory (supports '~')."
                ],
                "name_only": [
                    "type": "boolean",
                    "description": "Match file names only (default: false)."
                ],
                "limit": [
                    "type": "integer",
                    "description": "Max results (1-100, default: 25).",
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
        let returned: Int
        let hasMore: Bool
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
            guard !rawDir.contains("\0") else {
                return .failure("Chemin de dossier invalide.")
            }
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

        // Early-terminate `mdfind` once we have `limit + 1` paths so broad queries never buffer tens of megabytes.
        let result = try await NativeProcessRunner.run(
            executablePath: executablePath,
            arguments: cliArgs,
            timeoutSeconds: 15,
            maxOutputBytes: 512 * 1024,
            maxStdoutLines: limit + 1
        )

        if result.timedOut {
            return .failure("La recherche Spotlight a dépassé le délai de 15s.")
        }
        if result.exitCode != 0 {
            return .failure("Erreur Spotlight (code \(result.exitCode)) : \(result.stderr)")
        }

        let collectedPaths = result.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }

        let hasMore = result.stdoutTruncated || collectedPaths.count > limit
        let matches: [SpotlightMatch] = collectedPaths.prefix(limit).map { path in
            let url = URL(fileURLWithPath: path)
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            return SpotlightMatch(
                path: path,
                fileName: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                sizeBytes: values?.fileSize,
                modifiedAt: values?.contentModificationDate.map { ISO8601Codec.format($0) }
            )
        }

        let payload = SearchPayload(
            query: query,
            directory: resolvedDir,
            returned: matches.count,
            hasMore: hasMore,
            matches: matches
        )
        return .success(try ToolOutputFormatter.encodeJSON(payload))
    }
}
