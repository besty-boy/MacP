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
            try? FileManager.default.removeItem(atPath: socketPath + ".lock")
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

        // Second UnixSocketServer on the same path must fail atomically via O_EXLOCK without flashing a client!
        let duplicateServer = UnixSocketServer(socketPath: socketPath)
        #expect(throws: TransportError.self) {
            try duplicateServer.start { _, _ in }
        }

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
        try? await Task.sleep(for: .milliseconds(100))

        let disconnectedSnap = await service.currentSnapshot()
        #expect(disconnectedSnap.isClientConnected == false)

        await service.stop()
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        #expect(!FileManager.default.fileExists(atPath: socketPath + ".lock"))
    }

    @Test("UnixSocketClient.relay exits immediately when server closes socket even with idle stdio pipe")
    func relayExitsPromptlyOnServerDisconnect() async throws {
        let socketPath = "/tmp/macp-relay-\(UUID().uuidString.prefix(8)).sock"
        defer {
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: socketPath + ".lock")
        }

        let server = UnixSocketServer(socketPath: socketPath)
        try server.start { _, transport in
            try? await Task.sleep(for: .milliseconds(60))
            await transport.close()
        }

        // Open an idle POSIX pipe simulating stdin (write end stays open!) and stdout.
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        defer {
            try? stdinPipe.fileHandleForReading.close()
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
        }

        let stdio = StdioTransport(
            inputHandle: stdinPipe.fileHandleForReading,
            outputHandle: stdoutPipe.fileHandleForWriting,
            closeOnDeinit: false
        )
        let socket = try UnixSocketClient.connect(path: socketPath)

        let t0 = ContinuousClock.now
        await UnixSocketClient.relay(stdio: stdio, socket: socket)
        let elapsed = t0.duration(to: .now)

        // Relay must NOT hang waiting on the open stdin pipe once the socket closes!
        #expect(elapsed < .seconds(1))
        server.stopSync()
    }

    @Test("StdioTransport supports half-closed pipes (stdin EOF before stdout response completes)")
    func stdioHalfClosedPipeDeliversResponse() async throws {
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        defer {
            try? stdinPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stdoutPipe.fileHandleForWriting.close()
        }

        // Write a request and IMMEDIATELY close stdin write end (simulating `printf '...' | MacP --stdio --standalone`).
        let requestLine = Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8) + Data([0x0A])
        try stdinPipe.fileHandleForWriting.write(contentsOf: requestLine)
        try stdinPipe.fileHandleForWriting.close()

        let suite = "com.macp.halfclose.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = ToolSettingsStore(userDefaults: defaults)
        let auditDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macp-halfclose-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: auditDir) }

        let transport = StdioTransport(
            inputHandle: stdinPipe.fileHandleForReading,
            outputHandle: stdoutPipe.fileHandleForWriting,
            closeOnDeinit: false
        )

        await MacPBridgeService.runStandaloneStdio(
            registry: .defaultMacOSTools(),
            settings: settings,
            prompter: StaticPermissionPrompter(decision: .deny),
            auditLogger: AuditLogger(logFileURL: auditDir.appendingPathComponent("audit.jsonl")),
            transport: transport
        )

        try stdoutPipe.fileHandleForWriting.close()
        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let response = try JSONRPCCodec.makeDecoder().decode(JSONRPCResponse.self, from: outData)
        #expect(response.id == .int(7))
        #expect(response.result?["tools"]?.arrayValue?.count == 17)
    }
}
