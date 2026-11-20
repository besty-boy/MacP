import Foundation
import Testing
@testable import MacPCore

@Suite("Native macOS MCP Tools")
struct ToolsTests {
    @Test("SystemStatsTool returns valid native CPU, memory, disk, and battery JSON")
    func systemStatsExecution() async throws {
        let tool = SystemStatsTool()
        let result = try await tool.execute(arguments: [:])
        #expect(result.isError == false)

        let jsonString = try #require(result.content.first?.text)
        let data = Data(jsonString.utf8)
        let decoded = try JSONDecoder().decode(SystemStatsTool.SystemStatsPayload.self, from: data)

        #expect(decoded.cpu.logicalCores > 0)
        #expect(decoded.memory.totalGB > 0)
        #expect(decoded.memory.usagePercent >= 0 && decoded.memory.usagePercent <= 100)
        #expect(decoded.disk != nil)
        #expect((decoded.disk?.totalGB ?? 0) > 0)
        #expect(!decoded.macOSVersion.isEmpty)
        #expect(!decoded.hostName.isEmpty)
        #expect(decoded.uptimeSeconds >= 0)
    }

    @Test("ShortcutTool validates arguments and runs executable safely")
    func shortcutToolValidationAndExecution() async throws {
        let missingTool = ShortcutTool(executablePath: "/bin/echo")
        let missingResult = try await missingTool.execute(arguments: [:])
        #expect(missingResult.isError == true)

        let emptyResult = try await missingTool.execute(arguments: ["shortcut_name": "   "])
        #expect(emptyResult.isError == true)

        let echoResult = try await missingTool.execute(arguments: ["shortcut_name": "My Test Shortcut"])
        #expect(echoResult.isError == false)
        let text = try #require(echoResult.content.first?.text)
        #expect(text.contains("run My Test Shortcut"))
        #expect(text.contains("\"exitCode\" : 0"))
    }

    @Test("ShortcutTool reports non-zero exit codes as tool errors")
    func shortcutToolFailureExitCode() async throws {
        let failingTool = ShortcutTool(executablePath: "/usr/bin/false")
        let result = try await failingTool.execute(arguments: ["shortcut_name": "FailingShortcut"])
        #expect(result.isError == true)
    }

    @Test("CalendarEventsTool parses strict YYYY-MM-DD dates")
    func calendarDateParsing() {
        #expect(CalendarEventsTool.parseLocalDate("2026-11-20") != nil)
        #expect(CalendarEventsTool.parseLocalDate("2026-02-30") == nil)
        #expect(CalendarEventsTool.parseLocalDate("invalid") == nil)
        #expect(CalendarEventsTool.parseLocalDate("2026/11/20") == nil)
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
        #expect(appleScriptOutput.contains("\"output\" : \"4\""))

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
        let res = try await tool.execute(arguments: ["url": "javascript:alert(1)"])
        #expect(res.isError == true)
    }

    @Test("Default tool registry registers all 17 native macOS tools across 4 categories")
    func defaultRegistryCount() {
        let registry = MCPToolRegistry.defaultMacOSTools()
        #expect(registry.allTools.count == 17)

        let categories = Set(registry.allTools.map(\.category))
        #expect(categories == Set(ToolCategory.allCases))
        #expect(registry.tool(named: "macos_capture_screen")?.sensitivity == .critical)
        #expect(registry.tool(named: "macos_run_applescript")?.sensitivity == .critical)
        #expect(registry.tool(named: "macos_list_reminders") != nil)
        #expect(registry.tool(named: "macos_spotlight_search") != nil)
    }
}
