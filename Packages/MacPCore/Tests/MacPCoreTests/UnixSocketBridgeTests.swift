import Foundation
import Testing
@testable import MacPCore

@Suite("Unix Socket Bridge End-to-End")
struct UnixSocketBridgeTests {
    @Test("Client connects over Unix socket, completes MCP handshake, calls system stats, and receives tools/list_changed")
    func endToEndSocketMCPFlow() async throws {
        let socketPath = "/tmp/macp-test-\(UUID().uuidString.prefix(8)).sock"
        let suite = "com.macp.sockettest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = ToolSettingsStore(userDefaults: defaults)

        let auditDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macp-sock-audit-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(at: auditDir)
        }

        let service = MacPBridgeService(
            registry: .defaultMacOSTools(),
            settings: settings,
            permissionManager: PermissionManager(
                settings: settings,
                prompter: StaticPermissionPrompter(decision: .allowOnce)
            ),
            auditLogger: AuditLogger(logFileURL: auditDir.appendingPathComponent("audit.jsonl")),
            socketPath: socketPath
        )

        await service.start()
        let startSnap = await service.currentSnapshot()
        #expect(startSnap.isListening == true)
        #expect(startSnap.isClientConnected == false)

        // Connect a simulated `--stdio` client to the Unix socket
        let client = try UnixSocketClient.connect(path: socketPath)
        var lineIterator = client.incomingLines().makeAsyncIterator()

        // 1. Send initialize
        let initReq = Data(#"""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"Cursor","version":"1.2.3"}}}
        """#.utf8)
        try await client.sendLine(initReq)

        let initLine = try #require(await lineIterator.next())
        let initResp = try JSONRPCCodec.makeDecoder().decode(JSONRPCResponse.self, from: initLine)
        #expect(initResp.id == .int(1))
        #expect(initResp.result?["serverInfo"]?["name"]?.stringValue == "MacP")

        // Verify live dashboard snapshot sees "Cursor 1.2.3"
        let connectedSnap = await service.currentSnapshot()
        #expect(connectedSnap.isClientConnected == true)
        #expect(connectedSnap.connectedClients.first?.displayLabel == "Cursor 1.2.3")

        // 2. Send notifications/initialized
        try await client.sendLine(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))

        // 3. Call macos_system_stats (standard sensitivity, no alert needed)
        let statsReq = Data(#"""
        {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"macos_system_stats","arguments":{}}}
        """#.utf8)
        try await client.sendLine(statsReq)

        let statsLine = try #require(await lineIterator.next())
        let statsResp = try JSONRPCCodec.makeDecoder().decode(JSONRPCResponse.self, from: statsLine)
        #expect(statsResp.id == .int(2))
        #expect(statsResp.result?["isError"]?.boolValue == false)
        let statsText = statsResp.result?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(statsText.contains("logicalCores"))

        // 4. Trigger tools/list_changed broadcast
        await service.notifyToolsChanged()
        let notifLine = try #require(await lineIterator.next())
        let notif = try JSONRPCCodec.makeDecoder().decode(JSONRPCNotification.self, from: notifLine)
        #expect(notif.method == "notifications/tools/list_changed")

        // 5. Disconnect and verify cleanup
        await client.close()
        try? await Task.sleep(for: .milliseconds(150))

        let disconnectedSnap = await service.currentSnapshot()
        #expect(disconnectedSnap.isClientConnected == false)

        await service.stop()
    }
}
