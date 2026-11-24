import Darwin
import Foundation
import os

/// Abstraction for newline-delimited JSON-RPC 2.0 message transports.
public protocol NDJSONTransport: Sendable {
    var supportsHalfClose: Bool { get }
    func incomingLines() -> AsyncStream<Data>
    func sendLine(_ data: Data) async throws
    func close() async
}

extension NDJSONTransport {
    public var supportsHalfClose: Bool { false }
}

public enum TransportError: Error, LocalizedError, Sendable {
    case writeFailed(Int32)
    case closed
    case socketCreationFailed(Int32)
    case socketPathTooLong(String)
    case bindFailed(Int32, String)
    case listenFailed(Int32)
    case connectFailed(Int32, String)
    case peerRejected

    public var errorDescription: String? {
        switch self {
        case let .writeFailed(code):
            return "Transport write failed (errno \(code): \(String(cString: strerror(code))))"
        case .closed:
            return "Transport is closed"
        case let .socketCreationFailed(code):
            return "Failed to create Unix domain socket (errno \(code))"
        case let .socketPathTooLong(path):
            return "Unix socket path exceeds macOS limit: \(path)"
        case let .bindFailed(code, path):
            return "Failed to bind Unix socket at \(path) (errno \(code): \(String(cString: strerror(code))))"
        case let .listenFailed(code):
            return "Failed to listen on Unix socket (errno \(code))"
        case let .connectFailed(code, path):
            return "Failed to connect to Unix socket at \(path) (errno \(code): \(String(cString: strerror(code))))"
        case .peerRejected:
            return "Rejected Unix socket connection from unauthorized peer"
        }
    }
}

/// Event-driven POSIX file-descriptor NDJSON transport (`kqueue` via `DispatchSourceRead`).
/// - Zero permanently blocked reader threads.
/// - Zero FD-close race conditions (`cancelHandler` guarantees FDs close only after read callbacks drain).
/// - O(N) cursor-based line framing with bounded memory per frame.
public final class FileDescriptorTransport: NDJSONTransport, @unchecked Sendable {
    /// Maximum single NDJSON frame size (32 MiB — ample for high-res base64 screenshots while preventing OOM).
    public static let defaultMaxLineBytes = 32 * 1024 * 1024

    private struct LifecycleState: @unchecked Sendable {
        var isClosed = false
        var fdClosed = false
        var readSource: DispatchSourceRead?
        var continuation: AsyncStream<Data>.Continuation?
    }

    public var supportsHalfClose: Bool {
        readFD != writeFD
    }

    private let readFD: Int32
    private let writeFD: Int32
    private let closeOnDeinit: Bool
    private let isNonBlocking: Bool
    private let maxLineBytes: Int
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private let state = OSAllocatedUnfairLock(initialState: LifecycleState())
    private let writeLock = OSAllocatedUnfairLock()

    public init(
        readFD: Int32,
        writeFD: Int32,
        closeOnDeinit: Bool,
        isNonBlocking: Bool = false,
        maxLineBytes: Int = FileDescriptorTransport.defaultMaxLineBytes,
        label: String = "com.macp.transport.fd"
    ) {
        self.readFD = readFD
        self.writeFD = writeFD
        self.closeOnDeinit = closeOnDeinit
        self.isNonBlocking = isNonBlocking
        self.maxLineBytes = max(1024, maxLineBytes)
        self.readQueue = DispatchQueue(label: label + ".read", qos: .userInitiated)
        self.writeQueue = DispatchQueue(label: label + ".write", qos: .userInitiated)
        // Prevent SIGPIPE from killing the process when a peer disconnects abruptly.
        _ = signal(SIGPIPE, SIG_IGN)
    }

    deinit {
        if closeOnDeinit {
            closeSync()
        }
    }

    public func incomingLines() -> AsyncStream<Data> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let alreadyClosed = state.withLock { $0.isClosed }
            if alreadyClosed {
                continuation.finish()
                return
            }

            let source = DispatchSource.makeReadSource(fileDescriptor: readFD, queue: readQueue)
            var buffer = Data()
            var readOffset = 0
            var chunk = [UInt8](repeating: 0, count: 16_384)
            let newlineByte: UInt8 = 0x0A
            let carriageReturnByte: UInt8 = 0x0D

            let emitCompleteLines = {
                while readOffset < buffer.count {
                    guard let nlIndex = buffer[readOffset...].firstIndex(of: newlineByte) else {
                        break
                    }

                    var endIndex = nlIndex
                    if endIndex > readOffset && buffer[endIndex - 1] == carriageReturnByte {
                        endIndex -= 1
                    }

                    let slice = buffer[readOffset..<endIndex]
                    readOffset = nlIndex + 1

                    if !Self.isWhitespaceOnly(slice) {
                        continuation.yield(Data(slice))
                    }
                }

                // Compact consumed prefix periodically to keep O(N) amortized cost and low memory.
                if readOffset == buffer.count {
                    buffer.removeAll(keepingCapacity: buffer.count <= 65_536)
                    readOffset = 0
                } else if readOffset >= 16_384 {
                    buffer.removeSubrange(0..<readOffset)
                    readOffset = 0
                }
            }

            let flushTrailingAndFinish = {
                if readOffset < buffer.count {
                    var endIndex = buffer.count
                    if endIndex > readOffset && buffer[endIndex - 1] == carriageReturnByte {
                        endIndex -= 1
                    }
                    let trailing = buffer[readOffset..<endIndex]
                    if !Self.isWhitespaceOnly(trailing) {
                        continuation.yield(Data(trailing))
                    }
                    buffer.removeAll(keepingCapacity: false)
                    readOffset = 0
                }
                source.cancel()
            }

            source.setEventHandler { [weak self] in
                guard let self else {
                    source.cancel()
                    return
                }
                if self.checkClosed() {
                    source.cancel()
                    return
                }

                if self.isNonBlocking {
                    // Drain all currently available bytes until EAGAIN/EWOULDBLOCK or EOF.
                    while !self.checkClosed() {
                        let bytesRead = Darwin.read(self.readFD, &chunk, chunk.count)
                        if bytesRead > 0 {
                            let pendingBytes = (buffer.count - readOffset) + bytesRead
                            if pendingBytes > self.maxLineBytes {
                                DiagnosticLog.write("Transport frame exceeded \(self.maxLineBytes) bytes; closing connection")
                                buffer.removeAll(keepingCapacity: false)
                                readOffset = 0
                                source.cancel()
                                return
                            }
                            buffer.append(contentsOf: chunk[0..<bytesRead])
                            emitCompleteLines()
                        } else if bytesRead == 0 {
                            flushTrailingAndFinish()
                            return
                        } else {
                            let err = errno
                            if err == EINTR {
                                continue
                            }
                            if err == EAGAIN || err == EWOULDBLOCK {
                                break
                            }
                            source.cancel()
                            return
                        }
                    }
                } else {
                    // Blocking descriptor (e.g. stdin pipe or redirected file): only read up to `source.data` bytes.
                    let available = Int(source.data)
                    if available <= 0 {
                        flushTrailingAndFinish()
                        return
                    }

                    let toRead = min(available, chunk.count)
                    let bytesRead = Darwin.read(self.readFD, &chunk, toRead)
                    if bytesRead > 0 {
                        let pendingBytes = (buffer.count - readOffset) + bytesRead
                        if pendingBytes > self.maxLineBytes {
                            DiagnosticLog.write("Stdio frame exceeded \(self.maxLineBytes) bytes; closing transport")
                            buffer.removeAll(keepingCapacity: false)
                            readOffset = 0
                            source.cancel()
                            return
                        }
                        buffer.append(contentsOf: chunk[0..<bytesRead])
                        emitCompleteLines()
                    } else if bytesRead == 0 {
                        flushTrailingAndFinish()
                    } else if errno != EINTR {
                        source.cancel()
                    }
                }
            }

            source.setCancelHandler { [weak self] in
                continuation.finish()
                guard let self else { return }
                let shouldCloseFDs = self.state.withLock { s -> Bool in
                    s.readSource = nil
                    s.continuation = nil
                    // Only close descriptors if `close()`/`closeSync()` was explicitly invoked;
                    // a normal read-side EOF must keep `writeFD` open for half-closed pipes (e.g. `printf ... | MacP --stdio`).
                    guard s.isClosed, self.closeOnDeinit, !s.fdClosed else { return false }
                    s.fdClosed = true
                    return true
                }
                if shouldCloseFDs {
                    self.closeFileDescriptorsSafely()
                }
            }

            let started = state.withLock { s -> Bool in
                guard !s.isClosed else { return false }
                s.readSource = source
                s.continuation = continuation
                return true
            }

            guard started else {
                continuation.finish()
                return
            }

            continuation.onTermination = { [weak self] _ in
                self?.cancelReadSource()
            }

            source.resume()
        }
    }

    public func sendLine(_ data: Data) async throws {
        var payload = data
        if payload.last != 0x0A {
            payload.append(0x0A)
        }
        let frame = payload

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writeQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: TransportError.closed)
                    return
                }
                do {
                    try self.writeAll(frame)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func close() async {
        closeSync()
    }

    public func closeSync() {
        let action: (source: DispatchSourceRead?, shouldCloseFDsNow: Bool, continuation: AsyncStream<Data>.Continuation?) =
            state.withLock { s in
                if s.isClosed {
                    return (nil, false, nil)
                }
                s.isClosed = true
                if let src = s.readSource {
                    // Defer FD close to `cancelHandler` so no in-flight `read()` can race with `close()`.
                    return (src, false, nil)
                }
                let closeNow = closeOnDeinit && !s.fdClosed
                if closeNow {
                    s.fdClosed = true
                }
                let cont = s.continuation
                s.continuation = nil
                return (nil, closeNow, cont)
            }

        if let src = action.source {
            src.cancel()
        }
        action.continuation?.finish()
        if action.shouldCloseFDsNow {
            closeFileDescriptorsSafely()
        }
    }

    private func cancelReadSource() {
        let source = state.withLock { $0.readSource }
        source?.cancel()
    }

    private func checkClosed() -> Bool {
        state.withLock { $0.isClosed }
    }

    private func closeFileDescriptorsSafely() {
        writeLock.withLock {
            if readFD == writeFD {
                _ = Darwin.shutdown(readFD, SHUT_RDWR)
                _ = Darwin.close(readFD)
            } else {
                _ = Darwin.close(readFD)
                _ = Darwin.close(writeFD)
            }
        }
    }

    private func writeAll(_ data: Data) throws {
        try writeLock.withLock {
            if checkClosed() {
                throw TransportError.closed
            }

            try data.withUnsafeBytes { rawBuffer in
                guard let basePtr = rawBuffer.baseAddress else { return }
                var totalWritten = 0
                let totalBytes = rawBuffer.count

                while totalWritten < totalBytes {
                    if checkClosed() {
                        throw TransportError.closed
                    }

                    let written = Darwin.write(
                        writeFD,
                        basePtr.advanced(by: totalWritten),
                        totalBytes - totalWritten
                    )
                    if written > 0 {
                        totalWritten += written
                    } else if written < 0 {
                        let err = errno
                        if err == EINTR {
                            continue
                        }
                        if err == EAGAIN || err == EWOULDBLOCK {
                            var pfd = pollfd(fd: writeFD, events: Int16(POLLOUT), revents: 0)
                            let ready = Darwin.poll(&pfd, 1, 5_000)
                            if ready < 0 && errno == EINTR {
                                continue
                            }
                            if ready <= 0 || (pfd.revents & Int16(POLLERR | POLLHUP | POLLNVAL)) != 0 {
                                throw TransportError.writeFailed(err)
                            }
                            continue
                        }
                        throw TransportError.writeFailed(err)
                    } else {
                        throw TransportError.closed
                    }
                }
            }
        }
    }

    private static func isWhitespaceOnly(_ slice: Data.SubSequence) -> Bool {
        slice.allSatisfy { byte in
            byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
        }
    }
}

/// Event-driven stdio NDJSON transport reading `stdin` (`FileHandle.standardInput`) and writing `stdout` (`FileHandle.standardOutput`).
public final class StdioTransport: NDJSONTransport, @unchecked Sendable {
    private let inner: FileDescriptorTransport

    public init(
        inputHandle: FileHandle = .standardInput,
        outputHandle: FileHandle = .standardOutput,
        closeOnDeinit: Bool = false
    ) {
        self.inner = FileDescriptorTransport(
            readFD: inputHandle.fileDescriptor,
            writeFD: outputHandle.fileDescriptor,
            closeOnDeinit: closeOnDeinit,
            isNonBlocking: false,
            label: "com.macp.transport.stdio"
        )
    }

    public var supportsHalfClose: Bool {
        inner.supportsHalfClose
    }

    public func incomingLines() -> AsyncStream<Data> {
        inner.incomingLines()
    }

    public func sendLine(_ data: Data) async throws {
        try await inner.sendLine(data)
    }

    public func close() async {
        await inner.close()
    }
}
