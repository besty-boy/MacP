import Foundation
import Testing
@testable import MacPCore

@Suite("Local Audit Logger")
struct AuditLoggerTests {
    @Test("Persists JSONL entries, exports JSON/CSV, and reloads recent entries")
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
                resultPreview: "{\"ok\":true}"
            ))
        }

        let recent5 = await logger.recentEntries(limit: 5)
        #expect(recent5.count == 5)
        #expect(recent5[0].detail == "Run #7")
        #expect(recent5[4].detail == "Run #3")

        // Export JSON & CSV
        let exportedJSON = try await logger.exportJSON()
        #expect(String(decoding: exportedJSON, as: UTF8.self).contains("Run #7"))

        let exportedCSV = await logger.exportCSV()
        #expect(exportedCSV.hasPrefix("timestamp,client,method,tool,outcome,duration_ms,arguments,detail\n"))
        #expect(exportedCSV.contains("macos_system_stats"))

        // Reload from disk in a fresh AuditLogger instance
        let reloaded = AuditLogger(logFileURL: fileURL)
        let loadedRecent = await reloaded.recentEntries(limit: 5)
        #expect(loadedRecent.count == 5)
        #expect(loadedRecent[0].detail == "Run #7")
        #expect(loadedRecent[0].resultPreview == "{\"ok\":true}")

        // Clear wipes both memory and disk file
        await reloaded.clear()
        let afterClear = await reloaded.allLoadedEntries()
        #expect(afterClear.isEmpty)
    }
}
