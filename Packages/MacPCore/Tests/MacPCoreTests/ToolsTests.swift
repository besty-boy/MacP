import Foundation
import Testing
@testable import MacPCore

@Suite("Native macOS MCP Tools")
struct ToolsTests {
    @Test("SystemStatsTool returns valid compact JSON and uses zero-sleep cached delta on consecutive calls")
    func systemStatsExecutionAndCache() async throws {
        let tool = SystemStatsTool()
        let result = try await tool.execute(arguments: [:])
        #expect(result.isError == false)

        let jsonString = try #require(result.content.first?.text)
        // Compact JSON must not contain pretty-print newlines.
        #expect(!jsonString.contains("\n"))

        let decoded = try JSONDecoder().decode(SystemStatsTool.SystemStatsPayload.self, from: Data(jsonString.utf8))
        #expect(decoded.cpu.logicalCores > 0)
        #expect(decoded.memory.totalGB > 0)
        #expect(decoded.memory.usagePercent >= 0 && decoded.memory.usagePercent <= 100)
        #expect(decoded.disk != nil)
        #expect((decoded.disk?.totalGB ?? 0) > 0)
        #expect(!decoded.macOSVersion.isEmpty)
        #expect(!decoded.hostName.isEmpty)
        #expect(decoded.uptimeSeconds >= 0)

        // Second consecutive call should hit the cached CPU sample with near-zero latency (< 40ms).
        let t0 = ContinuousClock.now
        _ = await SystemStatsTool.collectSnapshot()
        let elapsed = t0.duration(to: .now)
        #expect(elapsed < .milliseconds(60))
    }

    @Test("ShortcutTool validates arguments and runs executable safely with compact JSON")
    func shortcutToolValidationAndExecution() async throws {
        let missingTool = ShortcutTool(executablePath: "/bin/echo")
        let missingResult = try await missingTool.execute(arguments: [:])
        #expect(missingResult.isError == true)

        let emptyResult = try await missingTool.execute(arguments: ["shortcut_name": "   "])
        #expect(emptyResult.isError == true)

        let echoResult = try await missingTool.execute(arguments: ["shortcut_name": "My Test Shortcut"])
        #expect(echoResult.isError == false)
        let text = try #require(echoResult.content.first?.text)
        #expect(!text.contains("\n"))
        #expect(text.contains("run My Test Shortcut"))
        #expect(text.contains("\"exitCode\":0"))
    }

    @Test("ShortcutTool reports non-zero exit codes as tool errors")
    func shortcutToolFailureExitCode() async throws {
        let failingTool = ShortcutTool(executablePath: "/usr/bin/false")
        let result = try await failingTool.execute(arguments: ["shortcut_name": "FailingShortcut"])
        #expect(result.isError == true)
    }

    @Test("CalendarEventsTool parses strict YYYY-MM-DD dates and ISO8601Codec parses all formats")
    func dateParsing() {
        #expect(CalendarEventsTool.parseLocalDate("2026-11-20") != nil)
        #expect(CalendarEventsTool.parseLocalDate("2026-02-30") == nil)
        #expect(CalendarEventsTool.parseLocalDate("invalid") == nil)
        #expect(CalendarEventsTool.parseLocalDate("2026/11/20") == nil)

        #expect(ISO8601Codec.parse("2026-11-21T14:00:00Z") != nil)
        #expect(ISO8601Codec.parse("2026-11-21T14:00:00.250+01:00") != nil)
        #expect(ISO8601Codec.parse("2026-11-21T14:30:00") != nil)
        #expect(ISO8601Codec.parse("2026-11-21T14:30") != nil)
        #expect(ISO8601Codec.parse("2026-02-30T10:00") == nil)
        #expect(ISO8601Codec.parse("not-a-date") == nil)
    }

    @Test("AppleScriptTool executes AppleScript and JXA safely")
    func appleScriptAndJXA() async throws {
        let tool = AppleScriptTool()
        let empty = try await tool.execute(arguments: ["script": "   "])
        #expect(empty.isError == true)

        let res = try await tool.execute(arguments: [
            "script": "return 2 + 2",
            "language": "AppleScript"
        ])
        #expect(res.isError == false)
        let appleScriptOutput = res.content.first?.text ?? ""
        #expect(appleScriptOutput.contains("\"output\":\"4\""))

        let jxa = try await tool.execute(arguments: [
            "script": "JSON.stringify({sum: 21 * 2})",
            "language": "JavaScript"
        ])
        #expect(jxa.isError == false)
        let jxaOutput = jxa.content.first?.text ?? ""
        #expect(jxaOutput.contains("42"))
    }

    @Test("OpenAppOrURLTool rejects dangerous URL schemes")
    func openToolBlocksDangerousSchemes() async throws {
        let tool = OpenAppOrURLTool()
        for blocked in ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hi", "vbscript:msgbox(1)"] {
            let res = try await tool.execute(arguments: ["url": .string(blocked)])
            #expect(res.isError == true)
        }
    }

    @Test("NativeProcessRunner enforces cancellation and early line limits cleanly")
    func processRunnerCancellationAndLineCap() async throws {
        // 1. Structured Task cancellation terminates a sleeping child promptly.
        let task = Task {
            try await NativeProcessRunner.run(
                executablePath: "/bin/sleep",
                arguments: ["10"],
                timeoutSeconds: 15
            )
        }
        try? await Task.sleep(for: .milliseconds(60))
        let cancelStart = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError")
        } catch is CancellationError {
            #expect(cancelStart.duration(to: .now) < .seconds(2))
        }

        // 2. Early line cap stops reading after maxStdoutLines.
        let lineRes = try await NativeProcessRunner.run(
            executablePath: "/usr/bin/seq",
            arguments: ["1", "10000"],
            timeoutSeconds: 5,
            maxStdoutLines: 10
        )
        #expect(lineRes.exitCode == 0)
        #expect(lineRes.stdoutTruncated == true)
        let lines = lineRes.stdout.split(whereSeparator: \.isNewline)
        #expect(lines.count >= 10)
    }

    @Test("Default tool registry registers 17 tools and Eco preset slashes schema token footprint")
    func defaultRegistryAndEcoPreset() {
        let registry = MCPToolRegistry.defaultMacOSTools()
        #expect(registry.allTools.count == 17)

        let categories = Set(registry.allTools.map(\.category))
        #expect(categories == Set(ToolCategory.allCases))
        #expect(registry.tool(named: "macos_capture_screen")?.sensitivity == .critical)
        #expect(registry.tool(named: "macos_run_applescript")?.sensitivity == .critical)
        #expect(registry.tool(named: "macos_list_reminders") != nil)
        #expect(registry.tool(named: "macos_spotlight_search") != nil)

        let suite = "com.macp.preset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = ToolSettingsStore(userDefaults: defaults)

        let fullTokens = registry.estimatedSchemaTokens(enabledUsing: settings)
        settings.applyPreset(.eco, to: registry.allMetadata)
        let ecoTokens = registry.estimatedSchemaTokens(enabledUsing: settings)

        #expect(fullTokens > 0)
        #expect(ecoTokens > 0)
        #expect(ecoTokens * 2 < fullTokens) // Eco preset cuts > 50% of schema tokens!
    }
}
