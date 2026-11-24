import Dispatch
import Foundation
import MacPCore

/// Custom entry point routing `--stdio` and CLI utility flags directly without initializing AppKit/SwiftUI,
/// while launching the Menu Bar app for normal GUI launches.
@main
struct MacPMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.contains("--help") || args.contains("-h") {
            let usage = """
            MacP — Native macOS MCP Bridge (v\(MacPVersion.current))

            Usage:
              MacP                        Launch the macOS Menu Bar app & local MCP bridge daemon
              MacP --stdio [options]      Run as a stdio MCP bridge for Antigravity / Claude / Cursor / Windsurf
              MacP --status [options]     Check if the MacP.app Unix socket daemon is reachable

            Options:
              --socket <path>             Custom Unix domain socket path (default: ~/Library/Application Support/MacP/macp.sock)
              --standalone                Run MCP server directly in-process without connecting to MacP.app
              --no-autolaunch             Do not automatically launch MacP.app if the socket is unavailable
              --allow-sensitive           (Testing only) Allow sensitive tools in standalone headless mode
              --version, -v               Print version information
              --help, -h                  Print this help message
            """
            writeStderr(usage + "\n")
            exit(0)
        }

        if args.contains("--version") || args.contains("-v") {
            writeStdout("MacP \(MacPVersion.current)\n")
            exit(0)
        }

        let options = StdioCLIOptions.parse(args)

        if args.contains("--status") {
            let reachable = UnixSocketServer.canConnect(path: options.socketPath)
            if reachable {
                writeStdout("MacP \(MacPVersion.current): listening on \(options.socketPath)\n")
                exit(0)
            } else {
                writeStderr("MacP \(MacPVersion.current): not reachable at \(options.socketPath)\n")
                exit(1)
            }
        }

        if args.contains("--stdio") {
            Task {
                let code = await StdioBridgeRunner.run(options: options)
                exit(code)
            }
            dispatchMain()
        }

        MacPMenuBarApp.main()
    }

    private static func writeStdout(_ text: String) {
        if let data = text.data(using: .utf8) {
            FileHandle.standardOutput.write(data)
        }
    }

    private static func writeStderr(_ text: String) {
        if let data = text.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}

private struct StdioCLIOptions: Sendable {
    let socketPath: String
    let standalone: Bool
    let autoLaunchApp: Bool
    let allowSensitiveHeadless: Bool

    static func parse(_ args: [String]) -> StdioCLIOptions {
        var socketPath = MacPSocketPath.defaultPath
        if let idx = args.firstIndex(of: "--socket"), idx + 1 < args.count {
            socketPath = args[idx + 1]
        }
        return StdioCLIOptions(
            socketPath: socketPath,
            standalone: args.contains("--standalone"),
            autoLaunchApp: !args.contains("--no-autolaunch"),
            allowSensitiveHeadless: args.contains("--allow-sensitive")
        )
    }
}

private enum StdioBridgeRunner {
    static func run(options: StdioCLIOptions) async -> Int32 {
        let stdio = StdioTransport()

        if !options.standalone {
            if let socket = await connectOrLaunchApp(
                socketPath: options.socketPath,
                autoLaunch: options.autoLaunchApp
            ) {
                DiagnosticLog.write("Stdio bridge attached to MacP.app socket at \(options.socketPath)")
                await UnixSocketClient.relay(stdio: stdio, socket: socket)
                return 0
            }
            DiagnosticLog.write("MacP.app socket unreachable; falling back to standalone stdio MCP server")
        }

        let settings = ToolSettingsStore()
        let fallbackDecision: ToolPermissionDecision = options.allowSensitiveHeadless ? .allowOnce : .deny
        await MacPBridgeService.runStandaloneStdio(
            registry: .defaultMacOSTools(),
            settings: settings,
            prompter: StaticPermissionPrompter(decision: fallbackDecision),
            auditLogger: AuditLogger(),
            transport: stdio
        )
        return 0
    }

    private static func connectOrLaunchApp(
        socketPath: String,
        autoLaunch: Bool
    ) async -> FileDescriptorTransport? {
        if let socket = try? UnixSocketClient.connect(path: socketPath) {
            return socket
        }

        guard autoLaunch, let appBundleURL = enclosingAppBundleURL() else {
            return nil
        }

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-g", "-a", appBundleURL.path]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        try? launcher.run()

        // Fast adaptive backoff: attaches in ~40-80ms on warm launches, tolerates up to ~5s on cold macOS boot.
        let retryDelaysMs: [Int] = [40, 60, 80, 100, 120, 150, 150, 200, 200, 250, 250, 300, 300, 400, 400, 500, 500, 500, 500]
        for delayMs in retryDelaysMs {
            try? await Task.sleep(for: .milliseconds(delayMs))
            if let socket = try? UnixSocketClient.connect(path: socketPath) {
                return socket
            }
        }
        return nil
    }

    private static func enclosingAppBundleURL() -> URL? {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var current = executableURL.deletingLastPathComponent()
        for _ in 0..<5 {
            if current.pathExtension == "app" {
                return current
            }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return nil
    }
}
