import Foundation
import Testing
@testable import MacPCore

@Suite("Local Audit Logger")
struct AuditLoggerTests {
    @Test("Persists JSONL entries, exports JSON/CSV with response_bytes, and reloads recent entries")
    func persistExportAndReload() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macp-audit-test-\(UUID().uuidString)", isDirectory: true)
        let fileURL = tempDir.appendingPathComponent("audit.jsonl")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let logger = AuditLogger(logFileURL: fileURL)

        for i in 1...7 {
            await logger.record(AuditEntry(
                clientName: "Cursor",
                method: "tools/call",
                toolName: "macos_system_stats",
                argumentsSummary: "{}",
                argumentsJSON: "{}",
                outcome: .success,
                durationMs: i * 10,
                detail: "Run #\(i)",
                resultPreview: "{\"ok\":true}",
                responseBytes: 120 + i
            ))
        }

        let recent5 = await logger.recentEntries(limit: 5)
        #expect(recent5.count == 5)
        #expect(recent5[0].detail == "Run #7")
        #expect(recent5[0].responseBytes == 127)
        #expect(recent5[4].detail == "Run #3")

        // Export JSON & CSV
        let exportedJSON = try await logger.exportJSON()
        #expect(String(decoding: exportedJSON, as: UTF8.self).contains("Run #7"))

        let exportedCSV = await logger.exportCSV()
        #expect(exportedCSV.hasPrefix("timestamp,client,method,tool,outcome,duration_ms,response_bytes,arguments,detail\n"))
        #expect(exportedCSV.contains("macos_system_stats"))
        #expect(exportedCSV.contains(",127,"))

        // Reload from disk in a fresh AuditLogger instance
        let reloaded = AuditLogger(logFileURL: fileURL)
        let loadedRecent = await reloaded.recentEntries(limit: 5)
        #expect(loadedRecent.count == 5)
        #expect(loadedRecent[0].detail == "Run #7")
        #expect(loadedRecent[0].resultPreview == "{\"ok\":true}")
        #expect(loadedRecent[0].responseBytes == 127)

        // Clear wipes both memory and disk file
        await reloaded.clear()
        let afterClear = await reloaded.allLoadedEntries()
        #expect(afterClear.isEmpty)
    }

    @Test("Automatically rotates audit.jsonl once maxFileBytes is exceeded")
    func automaticLogRotation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macp-audit-rotate-\(UUID().uuidString)", isDirectory: true)
        let fileURL = tempDir.appendingPathComponent("audit.jsonl")
        let backupURL = tempDir.appendingPathComponent("audit.1.jsonl")
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Small 4 KiB threshold to trigger rotation cleanly in test.
        let logger = AuditLogger(logFileURL: fileURL, maxInMemoryEntries: 100, maxFileBytes: 4096)
        let payload = String(repeating: "x", count: 350)

        for i in 1...25 {
            await logger.record(AuditEntry(
                clientName: "Antigravity",
                method: "tools/call",
                toolName: "macos_spotlight_search",
                argumentsSummary: "{}",
                outcome: .success,
                durationMs: 5,
                detail: "Entry #\(i)",
                resultPreview: payload,
                responseBytes: payload.utf8.count
            ))
        }

        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(FileManager.default.fileExists(atPath: backupURL.path))

        let activeSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64) ?? 0
        #expect(activeSize > 0)
        #expect(activeSize <= 4096)
    }
}
