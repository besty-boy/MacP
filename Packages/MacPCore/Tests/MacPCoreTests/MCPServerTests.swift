import Foundation
import Testing
@testable import MacPCore

private actor RecordingTransport: NDJSONTransport {
    private var sentLines: [Data] = []

    nonisolated func incomingLines() -> AsyncStream<Data> {
        AsyncStream { $0.finish() }
    }

    func sendLine(_ data: Data) async throws {
        sentLines.append(data)
    }

    func close() async {}

    func recordedMessages() -> [Data] {
        sentLines
    }
}

private actor CountingPrompter: PermissionPrompter {
    var requests: [ToolPermissionRequest] = []
    private var decisions: [ToolPermissionDecision]

    init(decisions: [ToolPermissionDecision]) {
        self.decisions = decisions
    }

    func requestPermission(for request: ToolPermissionRequest) async -> ToolPermissionDecision {
        requests.append(request)
        if decisions.isEmpty {
            return .deny
        }
        return decisions.removeFirst()
    }
}

private struct MockEchoTool: MCPTool {
    let name: String
    let displayName: String
    let shortSubtitle = "Test"
    let symbolName = "hammer"
    let description = "Mock tool for testing"
    let sensitivity: ToolSensitivity
    let permissionReason = "Test permission reason"

    var inputSchema: JSONValue {
        [
            "type": "object",
            "properties": [
                "message": ["type": "string"]
            ],
            "required": ["message"]
        ]
    }

    func execute(arguments: [String: JSONValue]) async throws -> MCPCallToolResult {
        let msg = arguments["message"]?.stringValue ?? "empty"
        return .success("echo:\(msg)")
    }
}

@Suite("MCP Server Protocol & Security")
struct MCPServerTests {
    private func makeIsolatedSettings() -> ToolSettingsStore {
        let suite = "com.macp.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ToolSettingsStore(userDefaults: defaults)
    }

    private func makeTempAuditLogger() -> AuditLogger {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macp-test-\(UUID().uuidString)", isDirectory: true)
        return AuditLogger(logFileURL: dir.appendingPathComponent("audit.jsonl"))
    }

    @Test("Initialize handshake advertises tools, resources, and prompts capabilities")
    func handshakeAndDiscovery() async throws {
        let settings = makeIsolatedSettings()
        let audit = makeTempAuditLogger()
        let prompter = CountingPrompter(decisions: [.allowOnce])
        let registry = MCPToolRegistry(tools: [
            MockEchoTool(name: "mock_standard", displayName: "Std", sensitivity: .standard),
            MockEchoTool(name: "mock_sensitive", displayName: "Sens", sensitivity: .sensitive)
        ])

        let session = MCPServerSession(
            registry: registry,
            settings: settings,
            permissionManager: PermissionManager(settings: settings, prompter: prompter),
            auditLogger: audit,
            transport: RecordingTransport()
        )

        // 1. initialize
        let initPayload = Data(#"""
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"Antigravity","version":"2.0"}}}
        """#.utf8)

        let initResp = await session.handleRawMessage(initPayload)
        #expect(initResp?.error == nil)
        #expect(initResp?.id == .int(1))
        #expect(initResp?.result?["protocolVersion"]?.stringValue == "2025-03-26")
        #expect(initResp?.result?["serverInfo"]?["name"]?.stringValue == "MacP")
        #expect(initResp?.result?["capabilities"]?["resources"] != nil)
        #expect(initResp?.result?["capabilities"]?["prompts"] != nil)

        // 2. notifications/initialized => MUST return nil
        let notifPayload = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        #expect(await session.handleRawMessage(notifPayload) == nil)

        // 3. ping
        let pingResp = await session.handleRawMessage(Data(#"{"jsonrpc":"2.0","id":"p1","method":"ping"}"#.utf8))
        #expect(pingResp?.error == nil)

        // 4. tools/list returns both enabled tools with annotations
        let listResp = await session.handleRawMessage(Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8))
        let tools = listResp?.result?["tools"]?.arrayValue ?? []
        #expect(tools.count == 2)
        #expect(tools.first?["annotations"]?["readOnlyHint"]?.boolValue == true)

        // 5. Disable one tool -> tools/list filters it out
        settings.setToolEnabled("mock_sensitive", enabled: false)
        let listResp2 = await session.handleRawMessage(Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#.utf8))
        let filteredTools = listResp2?.result?["tools"]?.arrayValue ?? []
        #expect(filteredTools.count == 1)
        #expect(filteredTools.first?["name"]?.stringValue == "mock_standard")
    }

    @Test("Permission flow: deny, 15-min lease, alwaysAllow, strict alwaysAsk, and Shield Mode")
    func permissionAndShieldEnforcement() async throws {
        let settings = makeIsolatedSettings()
        let audit = makeTempAuditLogger()
        let prompter = CountingPrompter(decisions: [.deny, .allowFor15Minutes, .allowAlways, .allowOnce])
        let registry = MCPToolRegistry(tools: [
            MockEchoTool(name: "mock_sensitive", displayName: "Sensitive Tool", sensitivity: .sensitive),
            MockEchoTool(name: "mock_critical", displayName: "Critical Tool", sensitivity: .critical)
        ])

        let permManager = PermissionManager(settings: settings, prompter: prompter)
        let session = MCPServerSession(
            registry: registry,
            settings: settings,
            permissionManager: permManager,
            auditLogger: audit,
            transport: RecordingTransport()
        )

        let callSensitive = Data(#"""
        {"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"mock_sensitive","arguments":{"message":"hello"}}}
        """#.utf8)

        // Call 1: Denied
        let deniedResp = await session.handleRawMessage(callSensitive)
        #expect(deniedResp?.result?["isError"]?.boolValue == true)
        #expect(await prompter.requests.count == 1)

        // Call 2: Allowed for 15 minutes
        let leaseResp = await session.handleRawMessage(callSensitive)
        #expect(leaseResp?.result?["isError"]?.boolValue == false)
        #expect(await prompter.requests.count == 2)
        #expect(await permManager.activeTemporaryGrants()["mock_sensitive"] != nil)

        // Call 3: Reuses 15-min lease without prompting
        let cachedLeaseResp = await session.handleRawMessage(callSensitive)
        #expect(cachedLeaseResp?.result?["isError"]?.boolValue == false)
        #expect(await prompter.requests.count == 2)

        // Critical tool defaults to alwaysAsk => even if prompter returns allowAlways, it MUST NOT cache!
        let callCritical = Data(#"""
        {"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"mock_critical","arguments":{"message":"script"}}}
        """#.utf8)

        let crit1 = await session.handleRawMessage(callCritical)
        #expect(crit1?.result?["isError"]?.boolValue == false)
        #expect(await prompter.requests.count == 3)
        #expect(settings.isAlwaysAllowed("mock_critical") == false)

        let crit2 = await session.handleRawMessage(callCritical)
        #expect(crit2?.result?["isError"]?.boolValue == false)
        #expect(await prompter.requests.count == 4)

        // Global Shield Mode blocks ALL calls AND hides all tools in tools/list
        settings.isShieldModeActive = true
        let shieldList = await session.handleRawMessage(Data(#"{"jsonrpc":"2.0","id":12,"method":"tools/list"}"#.utf8))
        let shieldTools = shieldList?.result?["tools"]?.arrayValue ?? []
        #expect(shieldTools.isEmpty)

        let shieldCall = await session.handleRawMessage(callSensitive)
        #expect(shieldCall?.result?["isError"]?.boolValue == true)
        let shieldText = shieldCall?.result?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(shieldText.contains("Bouclier"))
    }

    @Test("MCP Resources and Prompts list & fetch cleanly")
    func resourcesAndPrompts() async throws {
        let settings = makeIsolatedSettings()
        let audit = makeTempAuditLogger()
        let session = MCPServerSession(
            registry: .defaultMacOSTools(),
            settings: settings,
            permissionManager: PermissionManager(settings: settings, prompter: StaticPermissionPrompter(decision: .allowOnce)),
            auditLogger: audit,
            transport: RecordingTransport()
        )

        // resources/list
        let resList = await session.handleRawMessage(Data(#"{"jsonrpc":"2.0","id":20,"method":"resources/list"}"#.utf8))
        let resources = resList?.result?["resources"]?.arrayValue ?? []
        #expect(resources.count == 6)

        // resources/read for macos://system/stats
        let resRead = await session.handleRawMessage(Data(#"""
        {"jsonrpc":"2.0","id":21,"method":"resources/read","params":{"uri":"macos://system/stats"}}
        """#.utf8))
        #expect(resRead?.error == nil)
        let contentsText = resRead?.result?["contents"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(contentsText.contains("logicalCores"))

        // prompts/list
        let promptsList = await session.handleRawMessage(Data(#"{"jsonrpc":"2.0","id":22,"method":"prompts/list"}"#.utf8))
        let prompts = promptsList?.result?["prompts"]?.arrayValue ?? []
        #expect(prompts.count == 4)

        // prompts/get for daily_briefing
        let promptGet = await session.handleRawMessage(Data(#"""
        {"jsonrpc":"2.0","id":23,"method":"prompts/get","params":{"name":"daily_briefing","arguments":{"days":"3"}}}
        """#.utf8))
        #expect(promptGet?.error == nil)
        let promptText = promptGet?.result?["messages"]?.arrayValue?.first?["content"]?["text"]?.stringValue ?? ""
        #expect(promptText.contains("days: 3"))
    }

    @Test("Error codes for malformed JSON, invalid jsonrpc, unknown method, and unknown tool")
    func protocolErrors() async {
        let settings = makeIsolatedSettings()
        let audit = makeTempAuditLogger()
        let session = MCPServerSession(
            registry: MCPToolRegistry(tools: []),
            settings: settings,
            permissionManager: PermissionManager(settings: settings, prompter: StaticPermissionPrompter(decision: .deny)),
            auditLogger: audit,
            transport: RecordingTransport()
        )

        let parseErr = await session.handleRawMessage(Data("{broken".utf8))
        #expect(parseErr?.error?.code == -32700)

        let invalidReq = await session.handleRawMessage(Data(#"{"jsonrpc":"1.0","id":1,"method":"ping"}"#.utf8))
        #expect(invalidReq?.error?.code == -32600)

        let unknownMethod = await session.handleRawMessage(Data(#"{"jsonrpc":"2.0","id":2,"method":"foo/bar"}"#.utf8))
        #expect(unknownMethod?.error?.code == -32601)

        let unknownTool = await session.handleRawMessage(Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"does_not_exist"}}"#.utf8))
        #expect(unknownTool?.error?.code == -32602)
    }
}
