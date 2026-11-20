import Foundation

/// Logical category used to organize MCP tools in the Bento Dashboard UI.
public enum ToolCategory: String, Sendable, Codable, CaseIterable, Identifiable {
    case productivity
    case workspace
    case vision
    case automation

    public var id: String { rawValue }

    public var frenchTitle: String {
        switch self {
        case .productivity: return "Productivité"
        case .workspace: return "Système"
        case .vision: return "Vision"
        case .automation: return "Automation"
        }
    }

    public var symbolName: String {
        switch self {
        case .productivity: return "calendar.badge.checkmark"
        case .workspace: return "macwindow"
        case .vision: return "camera.viewfinder"
        case .automation: return "bolt.badge.automatic"
        }
    }
}

/// Metadata describing an MCP tool for both the protocol and the macOS Bento Dashboard UI.
public struct MCPToolMetadata: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let displayName: String
    public let shortSubtitle: String
    public let symbolName: String
    public let category: ToolCategory
    public let sensitivity: ToolSensitivity
    public let permissionReason: String

    public init(
        name: String,
        displayName: String,
        shortSubtitle: String,
        symbolName: String,
        category: ToolCategory = .productivity,
        sensitivity: ToolSensitivity,
        permissionReason: String
    ) {
        self.name = name
        self.displayName = displayName
        self.shortSubtitle = shortSubtitle
        self.symbolName = symbolName
        self.category = category
        self.sensitivity = sensitivity
        self.permissionReason = permissionReason
    }
}

/// Contract implemented by every native macOS MCP tool.
public protocol MCPTool: Sendable {
    var name: String { get }
    var displayName: String { get }
    var shortSubtitle: String { get }
    var symbolName: String { get }
    var category: ToolCategory { get }
    var description: String { get }
    var sensitivity: ToolSensitivity { get }
    var permissionReason: String { get }
    var inputSchema: JSONValue { get }
    var annotations: MCPToolAnnotations { get }

    func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult
}

extension MCPTool {
    public var category: ToolCategory { .productivity }

    public var annotations: MCPToolAnnotations {
        MCPToolAnnotations(
            title: displayName,
            readOnlyHint: sensitivity == .standard,
            destructiveHint: sensitivity == .critical,
            idempotentHint: sensitivity == .standard,
            openWorldHint: false
        )
    }

    public var definition: MCPToolDefinition {
        MCPToolDefinition(
            name: name,
            description: description,
            inputSchema: inputSchema,
            annotations: annotations
        )
    }

    public var metadata: MCPToolMetadata {
        MCPToolMetadata(
            name: name,
            displayName: displayName,
            shortSubtitle: shortSubtitle,
            symbolName: symbolName,
            category: category,
            sensitivity: sensitivity,
            permissionReason: permissionReason
        )
    }
}

/// Immutable registry of all available macOS MCP tools.
public struct MCPToolRegistry: Sendable {
    private let orderedTools: [any MCPTool]
    private let toolsByName: [String: any MCPTool]

    public init(tools: [any MCPTool]) {
        self.orderedTools = tools
        self.toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    public static func defaultMacOSTools() -> MCPToolRegistry {
        MCPToolRegistry(tools: [
            // Productivité Apple
            ListShortcutsTool(),
            ShortcutTool(),
            ClipboardTool(),
            WriteClipboardTool(),
            CalendarEventsTool(),
            CreateCalendarEventTool(),
            ListRemindersTool(),
            CreateReminderTool(),
            CompleteReminderTool(),
            SpotlightSearchTool(),
            NotificationTool(),
            // Workspace & Système
            SystemStatsTool(),
            RunningAppsTool(),
            OpenAppOrURLTool(),
            SystemControlsTool(),
            // Vision
            ScreenCaptureTool(),
            // Automatisation Pro
            AppleScriptTool()
        ])
    }

    public var allTools: [any MCPTool] {
        orderedTools
    }

    public var allMetadata: [MCPToolMetadata] {
        orderedTools.map(\.metadata)
    }

    public func tool(named name: String) -> (any MCPTool)? {
        toolsByName[name]
    }

    public func definitions(enabledUsing settings: ToolSettingsStore) -> [MCPToolDefinition] {
        guard !settings.isShieldModeActive else {
            return []
        }
        return orderedTools
            .filter { settings.isToolEnabled($0.name) }
            .map(\.definition)
    }
}

/// Helper for encoding structured tool output payloads as pretty-printed JSON.
enum ToolOutputFormatter {
    static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Shared safe subprocess runner used by native macOS CLI bridges (`/usr/bin/shortcuts`, `mdfind`, `osascript`, `screencapture`).
enum NativeProcessRunner {
    struct Result: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var stdoutData = Data()
        private var stderrData = Data()
        private var didTimeOut = false

        func setStdout(_ data: Data) { lock.withLock { stdoutData = data } }
        func setStderr(_ data: Data) { lock.withLock { stderrData = data } }
        func markTimedOut() { lock.withLock { didTimeOut = true } }

        func snapshot() -> (stdout: String, stderr: String, timedOut: Bool) {
            lock.withLock {
                (
                    String(decoding: stdoutData, as: UTF8.self),
                    String(decoding: stderrData, as: UTF8.self),
                    didTimeOut
                )
            }
        }
    }

    static func run(
        executablePath: String,
        arguments: [String],
        inputText: String? = nil,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executablePath)
                process.arguments = arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                var stdinPipe: Pipe?
                if inputText != nil {
                    let pipe = Pipe()
                    process.standardInput = pipe
                    stdinPipe = pipe
                } else {
                    process.standardInput = FileHandle.nullDevice
                }

                let outputQueue = DispatchQueue(label: "com.macp.process.pipes", attributes: .concurrent)
                let readGroup = DispatchGroup()
                let collector = OutputCollector()

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                if let inputText, let stdinPipe {
                    if let data = inputText.data(using: .utf8) {
                        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
                    }
                    try? stdinPipe.fileHandleForWriting.close()
                }

                readGroup.enter()
                outputQueue.async {
                    collector.setStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    readGroup.leave()
                }

                readGroup.enter()
                outputQueue.async {
                    collector.setStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    readGroup.leave()
                }

                let timeoutWork = DispatchWorkItem {
                    if process.isRunning {
                        collector.markTimedOut()
                        process.terminate()
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + timeoutSeconds,
                    execute: timeoutWork
                )

                process.waitUntilExit()
                timeoutWork.cancel()
                readGroup.wait()

                let result = collector.snapshot()
                continuation.resume(returning: Result(
                    exitCode: process.terminationStatus,
                    stdout: result.stdout,
                    stderr: result.stderr,
                    timedOut: result.timedOut
                ))
            }
        }
    }
}
