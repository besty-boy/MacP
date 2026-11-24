import Darwin
import Foundation
import os

/// Event-driven, cancellation-aware subprocess runner for native macOS CLIs
/// (`/usr/bin/shortcuts`, `mdfind`, `osascript`, `screencapture`).
/// - Zero permanently blocked `waitUntilExit()` threads (`terminationHandler` + async pipe readers).
/// - Supports structured Swift concurrency cancellation (`Task.cancel()` kills the subprocess).
/// - Enforces bounded output memory (`maxOutputBytes`) and optional early line cap (`maxStdoutLines`).
/// - Escalates `SIGTERM` to `SIGKILL` after a brief grace period so hung scripts never leak zombies.
enum NativeProcessRunner {
    struct Result: Sendable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
        let stdoutTruncated: Bool
    }

    static let defaultMaxOutputBytes = 2 * 1024 * 1024 // 2 MiB

    private static let ioQueue = DispatchQueue(
        label: "com.macp.process.io",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private final class RunController: @unchecked Sendable {
        private struct State: @unchecked Sendable {
            var stdoutData = Data()
            var stderrData = Data()
            var stdoutLines = 0
            var stdoutTruncated = false
            var stdoutClosed = false
            var stderrClosed = false
            var terminated = false
            var terminationStatus: Int32 = 0
            var timedOut = false
            var cancelled = false
            var stoppedEarlyForLineLimit = false
            var resumed = false
            var continuation: CheckedContinuation<Result, Error>?
            var timeoutTask: Task<Void, Never>?
            var killTask: Task<Void, Never>?
            var pipeDrainTask: Task<Void, Never>?
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let process: Process
        private let stdoutHandle: FileHandle
        private let stderrHandle: FileHandle
        private let maxOutputBytes: Int
        private let maxStdoutLines: Int?

        init(
            process: Process,
            stdoutHandle: FileHandle,
            stderrHandle: FileHandle,
            maxOutputBytes: Int,
            maxStdoutLines: Int?
        ) {
            self.process = process
            self.stdoutHandle = stdoutHandle
            self.stderrHandle = stderrHandle
            self.maxOutputBytes = max(1024, maxOutputBytes)
            self.maxStdoutLines = maxStdoutLines
        }

        func start(
            inputText: String?,
            stdinHandle: FileHandle?,
            timeoutSeconds: TimeInterval,
            continuation: CheckedContinuation<Result, Error>
        ) {
            state.withLock { $0.continuation = continuation }

            // Attach non-blocking readability handlers before launching so no pipe buffer can deadlock.
            stdoutHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                self?.handleStdout(data)
            }

            stderrHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                self?.handleStderr(data)
            }

            process.terminationHandler = { [weak self] proc in
                self?.handleTermination(status: proc.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                cleanupHandlers()
                resumeOnce(.failure(error))
                return
            }

            // Write stdin asynchronously on ioQueue so large scripts never block the caller thread.
            if let stdinHandle {
                NativeProcessRunner.ioQueue.async {
                    if let inputText, let data = inputText.data(using: .utf8) {
                        try? stdinHandle.write(contentsOf: data)
                    }
                    try? stdinHandle.close()
                }
            }

            // Schedule timeout guard with SIGTERM -> SIGKILL escalation.
            let timeout = max(0.1, timeoutSeconds)
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.triggerTimeout()
            }
            state.withLock { $0.timeoutTask = timeoutTask }
        }

        func cancel() {
            let shouldKill = state.withLock { s -> Bool in
                guard !s.resumed else { return false }
                s.cancelled = true
                s.timeoutTask?.cancel()
                s.timeoutTask = nil
                return true
            }
            guard shouldKill else { return }

            terminateAndEscalate()
            cleanupHandlers()
            resumeOnce(.failure(CancellationError()))
        }

        private func handleStdout(_ data: Data) {
            if data.isEmpty {
                stdoutHandle.readabilityHandler = nil
                state.withLock { $0.stdoutClosed = true }
                tryCompleteIfReady()
                return
            }

            let reachedLineLimit: Bool = state.withLock { s in
                let remaining = maxOutputBytes - s.stdoutData.count
                if remaining > 0 {
                    if data.count <= remaining {
                        s.stdoutData.append(data)
                    } else {
                        s.stdoutData.append(data.prefix(remaining))
                        s.stdoutTruncated = true
                    }
                } else {
                    s.stdoutTruncated = true
                }

                if let lineCap = maxStdoutLines {
                    for byte in data where byte == 0x0A {
                        s.stdoutLines += 1
                    }
                    if s.stdoutLines >= lineCap && !s.stoppedEarlyForLineLimit {
                        s.stoppedEarlyForLineLimit = true
                        s.stdoutTruncated = true
                        return true
                    }
                }
                return false
            }

            if reachedLineLimit {
                stdoutHandle.readabilityHandler = nil
                state.withLock { $0.stdoutClosed = true }
                terminateAndEscalate()
                tryCompleteIfReady()
            }
        }

        private func handleStderr(_ data: Data) {
            if data.isEmpty {
                stderrHandle.readabilityHandler = nil
                state.withLock { $0.stderrClosed = true }
                tryCompleteIfReady()
                return
            }

            state.withLock { s in
                let remaining = maxOutputBytes - s.stderrData.count
                if remaining > 0 {
                    if data.count <= remaining {
                        s.stderrData.append(data)
                    } else {
                        s.stderrData.append(data.prefix(remaining))
                    }
                }
            }
        }

        private func handleTermination(status: Int32) {
            let needsDrainTimer = state.withLock { s -> Bool in
                s.terminated = true
                s.terminationStatus = status
                s.timeoutTask?.cancel()
                s.timeoutTask = nil
                s.killTask?.cancel()
                s.killTask = nil
                return !(s.stdoutClosed && s.stderrClosed)
            }

            if !needsDrainTimer {
                tryCompleteIfReady()
                return
            }

            // Safety bound: if a background grandchild kept stdout/stderr open after main process exit, finish after 150ms.
            let drainTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, !Task.isCancelled else { return }
                self.cleanupHandlers()
                self.state.withLock {
                    $0.stdoutClosed = true
                    $0.stderrClosed = true
                }
                self.tryCompleteIfReady()
            }
            state.withLock { $0.pipeDrainTask = drainTask }
        }

        private func triggerTimeout() {
            let shouldTerminate = state.withLock { s -> Bool in
                guard !s.terminated && !s.resumed else { return false }
                s.timedOut = true
                return true
            }
            guard shouldTerminate else { return }
            terminateAndEscalate()
        }

        private func terminateAndEscalate() {
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            process.terminate() // SIGTERM

            // Escalate to SIGKILL if the process ignores SIGTERM.
            let killTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.process.isRunning else { return }
                if pid > 0 {
                    _ = Darwin.kill(pid, SIGKILL)
                }
            }
            state.withLock { s in
                s.killTask?.cancel()
                s.killTask = killTask
            }
        }

        private func tryCompleteIfReady() {
            let readyResult: Swift.Result<Result, Error>? = state.withLock { s in
                guard !s.resumed, s.terminated, s.stdoutClosed, s.stderrClosed else {
                    return nil
                }
                s.pipeDrainTask?.cancel()
                s.pipeDrainTask = nil

                if s.cancelled {
                    return .failure(CancellationError())
                }

                // If we intentionally terminated early because `maxStdoutLines` was satisfied, report exitCode 0.
                let effectiveExitCode: Int32 = s.stoppedEarlyForLineLimit ? 0 : s.terminationStatus
                return .success(Result(
                    exitCode: effectiveExitCode,
                    stdout: String(decoding: s.stdoutData, as: UTF8.self),
                    stderr: String(decoding: s.stderrData, as: UTF8.self),
                    timedOut: s.timedOut,
                    stdoutTruncated: s.stdoutTruncated
                ))
            }

            if let readyResult {
                cleanupHandlers()
                resumeOnce(readyResult)
            }
        }

        private func cleanupHandlers() {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        private func resumeOnce(_ result: Swift.Result<Result, Error>) {
            let cont: CheckedContinuation<Result, Error>? = state.withLock { s in
                guard !s.resumed else { return nil }
                s.resumed = true
                s.timeoutTask?.cancel()
                s.timeoutTask = nil
                s.killTask?.cancel()
                s.killTask = nil
                s.pipeDrainTask?.cancel()
                s.pipeDrainTask = nil
                let c = s.continuation
                s.continuation = nil
                return c
            }
            cont?.resume(with: result)
        }
    }

    static func run(
        executablePath: String,
        arguments: [String],
        inputText: String? = nil,
        timeoutSeconds: TimeInterval = 30,
        maxOutputBytes: Int = defaultMaxOutputBytes,
        maxStdoutLines: Int? = nil
    ) async throws -> Result {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinHandle: FileHandle?
        if inputText != nil {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            stdinHandle = stdinPipe.fileHandleForWriting
        } else {
            process.standardInput = FileHandle.nullDevice
            stdinHandle = nil
        }

        let controller = RunController(
            process: process,
            stdoutHandle: stdoutPipe.fileHandleForReading,
            stderrHandle: stderrPipe.fileHandleForReading,
            maxOutputBytes: maxOutputBytes,
            maxStdoutLines: maxStdoutLines
        )

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                controller.start(
                    inputText: inputText,
                    stdinHandle: stdinHandle,
                    timeoutSeconds: timeoutSeconds,
                    continuation: continuation
                )
            }
        } onCancel: {
            controller.cancel()
        }
    }
}
