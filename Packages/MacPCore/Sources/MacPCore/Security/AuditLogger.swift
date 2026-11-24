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
    public let responseBytes: Int?

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
        resultPreview: String? = nil,
        responseBytes: Int? = nil
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
        self.responseBytes = responseBytes
    }

    public var estimatedResponseTokens: Int {
        if let responseBytes {
            return TokenEstimator.estimate(utf8Bytes: responseBytes)
        }
        if let resultPreview {
            return TokenEstimator.estimate(text: resultPreview)
        }
        return 0
    }
}

/// Local-first JSONL audit logger storing every AI action in `~/Library/Logs/MacP/audit.jsonl`.
/// - O(1) in-memory append (no array shifting on every record).
/// - Tail-reads only the last 512 KiB on launch (O(1) startup memory regardless of log history).
/// - Persistent append `FileHandle` with automatic log rotation (5 MiB cap + 1 backup).
public actor AuditLogger {
    public nonisolated let logFileURL: URL
    private let maxInMemoryEntries: Int
    private let maxFileBytes: UInt64

    /// Stored chronologically (oldest -> newest) for O(1) append; exposed newest-first.
    private var chronologicalEntries: [AuditEntry] = []
    private var observers: [UUID: AsyncStream<AuditEntry>.Continuation] = [:]
    private var fileHandle: FileHandle?
    private var currentFileSize: UInt64 = 0

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
        maxInMemoryEntries: Int = 500,
        maxFileBytes: UInt64 = 5 * 1024 * 1024
    ) {
        self.logFileURL = logFileURL
        self.maxInMemoryEntries = max(1, maxInMemoryEntries)
        self.maxFileBytes = max(4096, maxFileBytes)
        let loadedNewestFirst = Self.loadTailEntries(from: logFileURL, limit: self.maxInMemoryEntries, decoder: decoder)
        self.chronologicalEntries = loadedNewestFirst.reversed()
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logFileURL.path),
           let size = attrs[.size] as? UInt64 {
            self.currentFileSize = size
        }
    }

    deinit {
        try? fileHandle?.close()
    }

    public func record(_ entry: AuditEntry) {
        chronologicalEntries.append(entry)
        if chronologicalEntries.count > maxInMemoryEntries {
            chronologicalEntries.removeFirst(chronologicalEntries.count - maxInMemoryEntries)
        }

        appendToDisk(entry)

        for continuation in observers.values {
            continuation.yield(entry)
        }
    }

    public func recentEntries(limit: Int = 5) -> [AuditEntry] {
        guard limit > 0 else { return [] }
        return Array(chronologicalEntries.suffix(limit).reversed())
    }

    public func allLoadedEntries() -> [AuditEntry] {
        Array(chronologicalEntries.reversed())
    }

    public func exportJSON() throws -> Data {
        let prettyEncoder = JSONEncoder()
        prettyEncoder.dateEncodingStrategy = .iso8601
        prettyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try prettyEncoder.encode(Array(chronologicalEntries.reversed()))
    }

    public func exportCSV() -> String {
        var lines = ["timestamp,client,method,tool,outcome,duration_ms,response_bytes,arguments,detail"]
        lines.reserveCapacity(chronologicalEntries.count + 1)
        for e in chronologicalEntries.reversed() {
            let row = [
                ISO8601Codec.format(e.timestamp),
                e.clientName,
                e.method,
                e.toolName ?? "",
                e.outcome.rawValue,
                String(e.durationMs),
                e.responseBytes.map(String.init) ?? "",
                e.argumentsSummary,
                e.detail
            ].map(Self.csvEscape).joined(separator: ",")
            lines.append(row)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public func clear() {
        chronologicalEntries.removeAll()
        try? fileHandle?.close()
        fileHandle = nil
        currentFileSize = 0
        try? Data().write(to: logFileURL, options: .atomic)
        let backupURL = rotatedBackupURL()
        try? FileManager.default.removeItem(at: backupURL)
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
        let cleaned = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        if cleaned.contains(",") || cleaned.contains("\"") {
            return "\"" + cleaned.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return cleaned
    }

    private func rotatedBackupURL() -> URL {
        let base = logFileURL.deletingPathExtension().lastPathComponent
        let ext = logFileURL.pathExtension
        let name = ext.isEmpty ? "\(base).1" : "\(base).1.\(ext)"
        return logFileURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    private func rotateIfNeeded(adding incomingBytes: UInt64) {
        guard currentFileSize + incomingBytes > maxFileBytes else { return }

        try? fileHandle?.close()
        fileHandle = nil

        let fm = FileManager.default
        let backup = rotatedBackupURL()
        try? fm.removeItem(at: backup)
        if fm.fileExists(atPath: logFileURL.path) {
            try? fm.moveItem(at: logFileURL, to: backup)
        }
        currentFileSize = 0
    }

    private func ensureAppendHandle() throws -> FileHandle {
        if let existing = fileHandle {
            return existing
        }

        let fm = FileManager.default
        let directory = logFileURL.deletingLastPathComponent()
        try fm.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(
                atPath: logFileURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
            currentFileSize = 0
        }

        let handle = try FileHandle(forWritingTo: logFileURL)
        currentFileSize = try handle.seekToEnd()
        fileHandle = handle
        return handle
    }

    private func appendToDisk(_ entry: AuditEntry) {
        do {
            var data = try encoder.encode(entry)
            data.append(0x0A)

            rotateIfNeeded(adding: UInt64(data.count))
            let handle = try ensureAppendHandle()
            try handle.write(contentsOf: data)
            currentFileSize += UInt64(data.count)
        } catch {
            // Reset handle in case the underlying file was moved/deleted externally.
            try? fileHandle?.close()
            fileHandle = nil
            DiagnosticLog.write("Failed to append audit entry: \(error.localizedDescription)")
        }
    }

    /// Reads at most the trailing `maxReadBytes` of the JSONL file so startup stays fast and memory-bounded.
    private static func loadTailEntries(
        from url: URL,
        limit: Int,
        decoder: JSONDecoder,
        maxReadBytes: UInt64 = 512 * 1024
    ) -> [AuditEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return []
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else {
            return []
        }

        let startOffset = fileSize > maxReadBytes ? (fileSize - maxReadBytes) : 0
        try? handle.seek(toOffset: startOffset)
        guard let tailData = try? handle.readToEnd(), !tailData.isEmpty else {
            return []
        }

        let content = String(decoding: tailData, as: UTF8.self)
        var lines = content.split(whereSeparator: \.isNewline)
        // If we started mid-file, drop the first potentially truncated line fragment.
        if startOffset > 0 && !lines.isEmpty {
            lines.removeFirst()
        }

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
/// Reuses an open handle and automatically rotates once the file reaches 2 MiB.
public enum DiagnosticLog {
    private static let queue = DispatchQueue(label: "com.macp.diagnostic-log", qos: .utility)
    private static let maxLogBytes: UInt64 = 2 * 1024 * 1024

    private final class Sink: @unchecked Sendable {
        var handle: FileHandle?
        var path: String?
        var size: UInt64 = 0
    }
    private static let sink = Sink()

    public static var logFileURL: URL {
        let logsDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MacP", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MacP", isDirectory: true)
        return logsDir.appendingPathComponent("macp.log")
    }

    public static func write(_ message: String, fileURL: URL? = nil) {
        let targetURL = fileURL ?? logFileURL
        let timestamp = ISO8601Codec.format(Date())
        let line = "[\(timestamp)] \(message)\n"
        queue.async {
            do {
                guard let data = line.data(using: .utf8) else { return }
                let fm = FileManager.default
                let isCustomTarget = (fileURL != nil)

                if !isCustomTarget {
                    if sink.path != targetURL.path || sink.handle == nil {
                        try? sink.handle?.close()
                        sink.handle = nil
                        try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        if !fm.fileExists(atPath: targetURL.path) {
                            fm.createFile(atPath: targetURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                        }
                        let handle = try FileHandle(forWritingTo: targetURL)
                        sink.size = try handle.seekToEnd()
                        sink.handle = handle
                        sink.path = targetURL.path
                    }

                    if sink.size + UInt64(data.count) > maxLogBytes {
                        try? sink.handle?.close()
                        sink.handle = nil
                        let backup = targetURL.deletingLastPathComponent().appendingPathComponent("macp.1.log")
                        try? fm.removeItem(at: backup)
                        try? fm.moveItem(at: targetURL, to: backup)
                        fm.createFile(atPath: targetURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                        let handle = try FileHandle(forWritingTo: targetURL)
                        sink.handle = handle
                        sink.size = 0
                    }

                    try sink.handle?.write(contentsOf: data)
                    sink.size += UInt64(data.count)
                } else {
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !fm.fileExists(atPath: targetURL.path) {
                        fm.createFile(atPath: targetURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    }
                    let handle = try FileHandle(forWritingTo: targetURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                }
            } catch {
                try? sink.handle?.close()
                sink.handle = nil
                // Intentionally silent: never write diagnostic failures to stdout.
            }
        }
    }
}
