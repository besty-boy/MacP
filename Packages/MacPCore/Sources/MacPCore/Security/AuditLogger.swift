import Foundation

public enum AuditOutcome: String, Sendable, Codable, Equatable {
    case success
    case denied
    case error
}

/// A single auditable MCP tool or resource event recorded locally on disk.
public struct AuditEntry: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let clientName: String
    public let method: String
    public let toolName: String?
    public let argumentsSummary: String
    public let argumentsJSON: String?
    public let outcome: AuditOutcome
    public let durationMs: Int
    public let detail: String
    public let resultPreview: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        clientName: String,
        method: String,
        toolName: String? = nil,
        argumentsSummary: String = "{}",
        argumentsJSON: String? = nil,
        outcome: AuditOutcome,
        durationMs: Int = 0,
        detail: String = "",
        resultPreview: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.clientName = clientName
        self.method = method
        self.toolName = toolName
        self.argumentsSummary = argumentsSummary
        self.argumentsJSON = argumentsJSON
        self.outcome = outcome
        self.durationMs = durationMs
        self.detail = detail
        self.resultPreview = resultPreview
    }
}

/// Local-first JSONL audit logger storing every AI action in `~/Library/Logs/MacP/audit.jsonl`.
public actor AuditLogger {
    public nonisolated let logFileURL: URL
    private let maxInMemoryEntries: Int
    private var entries: [AuditEntry] = []
    private var observers: [UUID: AsyncStream<AuditEntry>.Continuation] = [:]

    private let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return enc
    }()

    private let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()

    public static var defaultLogFileURL: URL {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MacP", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacP", isDirectory: true)
        return logsDir.appendingPathComponent("audit.jsonl")
    }

    public init(
        logFileURL: URL = AuditLogger.defaultLogFileURL,
        maxInMemoryEntries: Int = 500
    ) {
        self.logFileURL = logFileURL
        self.maxInMemoryEntries = maxInMemoryEntries
        self.entries = Self.loadExistingEntries(from: logFileURL, limit: maxInMemoryEntries, decoder: decoder)
    }

    public func record(_ entry: AuditEntry) {
        entries.insert(entry, at: 0)
        if entries.count > maxInMemoryEntries {
            entries.removeLast(entries.count - maxInMemoryEntries)
        }

        appendToDisk(entry)

        for continuation in observers.values {
            continuation.yield(entry)
        }
    }

    public func recentEntries(limit: Int = 5) -> [AuditEntry] {
        Array(entries.prefix(max(0, limit)))
    }

    public func allLoadedEntries() -> [AuditEntry] {
        entries
    }

    public func exportJSON() throws -> Data {
        let prettyEncoder = JSONEncoder()
        prettyEncoder.dateEncodingStrategy = .iso8601
        prettyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try prettyEncoder.encode(entries)
    }

    public func exportCSV() -> String {
        let iso = ISO8601DateFormatter()
        var lines = ["timestamp,client,method,tool,outcome,duration_ms,arguments,detail"]
        for e in entries {
            let row = [
                iso.string(from: e.timestamp),
                e.clientName,
                e.method,
                e.toolName ?? "",
                e.outcome.rawValue,
                String(e.durationMs),
                e.argumentsSummary,
                e.detail
            ].map(Self.csvEscape).joined(separator: ",")
            lines.append(row)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func clear() {
        entries.removeAll()
        try? Data().write(to: logFileURL, options: .atomic)
    }

    public func subscribe() -> AsyncStream<AuditEntry> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id: id) }
            }
        }
    }

    private func removeObserver(id: UUID) {
        observers.removeValue(forKey: id)
    }

    private static func csvEscape(_ value: String) -> String {
        let cleaned = value.replacingOccurrences(of: "\n", with: " ")
        if cleaned.contains(",") || cleaned.contains("\"") {
            return "\"" + cleaned.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return cleaned
    }

    private func appendToDisk(_ entry: AuditEntry) {
        do {
            let directory = logFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )

            var data = try encoder.encode(entry)
            data.append(0x0A)

            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let handle = try FileHandle(forWritingTo: logFileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: logFileURL, options: .atomic)
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: logFileURL.path
                )
            }
        } catch {
            DiagnosticLog.write("Failed to append audit entry: \(error.localizedDescription)")
        }
    }

    private static func loadExistingEntries(from url: URL, limit: Int, decoder: JSONDecoder) -> [AuditEntry] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        let lines = content.split(whereSeparator: \.isNewline)
        var parsed: [AuditEntry] = []
        parsed.reserveCapacity(min(lines.count, limit))

        for line in lines.reversed() {
            guard let data = line.data(using: .utf8),
                  let entry = try? decoder.decode(AuditEntry.self, from: data) else {
                continue
            }
            parsed.append(entry)
            if parsed.count >= limit { break }
        }
        return parsed
    }
}

/// File-based diagnostic logger that NEVER touches `stdout` (safe during MCP stdio sessions).
public enum DiagnosticLog {
    private static let queue = DispatchQueue(label: "com.macp.diagnostic-log", qos: .utility)

    public static var logFileURL: URL {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MacP", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacP", isDirectory: true)
        return logsDir.appendingPathComponent("macp.log")
    }

    public static func write(_ message: String, fileURL: URL? = nil) {
        let targetURL = fileURL ?? logFileURL
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        queue.async {
            do {
                let dir = targetURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                guard let data = line.data(using: .utf8) else { return }
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    let handle = try FileHandle(forWritingTo: targetURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: targetURL, options: .atomic)
                }
            } catch {
                // Intentionally silent: never write diagnostic failures to stdout.
            }
        }
    }
}
