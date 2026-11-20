import Darwin
import Foundation

/// Abstraction for newline-delimited JSON-RPC 2.0 message transports.
public protocol NDJSONTransport: Sendable {
    func incomingLines() -> AsyncStream<Data>
    func sendLine(_ data: Data) async throws
    func close() async
}

public enum TransportError: Error, LocalizedError, Sendable {
    case writeFailed(Int32)
    case closed
    case socketCreationFailed(Int32)
    case socketPathTooLong(String)
    case bindFailed(Int32, String)
    case listenFailed(Int32)
    case connectFailed(Int32, String)

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
        }
    }
}

/// Low-level POSIX file-descriptor NDJSON transport used by both `stdin`/`stdout` and Unix sockets.
public final class FileDescriptorTransport: NDJSONTransport, @unchecked Sendable {
    private let readFD: Int32
    private let writeFD: Int32
    private let closeOnDeinit: Bool
    private let readQueue: DispatchQueue
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private var isClosed = false

    public init(
        readFD: Int32,
        writeFD: Int32,
        closeOnDeinit: Bool,
        label: String = "com.macp.transport.fd"
    ) {
        self.readFD = readFD
        self.writeFD = writeFD
        self.closeOnDeinit = closeOnDeinit
        self.readQueue = DispatchQueue(label: label, qos: .userInitiated)
        // Prevent SIGPIPE from killing the process when a peer disconnects abruptly.
        _ = signal(SIGPIPE, SIG_IGN)
    }

    deinit {
        if closeOnDeinit {
            closeSync()
        }
    }

    public func incomingLines() -> AsyncStream<Data> {
        AsyncStream { continuation in
            readQueue.async { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }

                var buffer = Data()
                var chunk = [UInt8](repeating: 0, count: 4096)
                let newlineByte: UInt8 = 0x0A
                let carriageReturnByte: UInt8 = 0x0D

                while !self.checkClosed() {
                    let bytesRead = Darwin.read(self.readFD, &chunk, chunk.count)
                    if bytesRead > 0 {
                        buffer.append(contentsOf: chunk[0..<bytesRead])

                        while let nlIndex = buffer.firstIndex(of: newlineByte) {
                            var line = buffer.prefix(upTo: nlIndex)
                            buffer.removeSubrange(...nlIndex)

                            if line.last == carriageReturnByte {
                                line = line.dropLast()
                            }

                            let trimmed = Data(line)
                            if !Self.isWhitespaceOnly(trimmed) {
                                continuation.yield(trimmed)
                            }
                        }
                    } else if bytesRead == 0 {
                        // EOF: emit any trailing non-empty JSON frame before closing.
                        if !Self.isWhitespaceOnly(buffer) {
                            continuation.yield(buffer)
                        }
                        break
                    } else {
                        let err = errno
                        if err == EINTR {
                            continue
                        }
                        break
                    }
                }

                continuation.finish()
            }
        }
    }

    public func sendLine(_ data: Data) async throws {
        var payload = data
        if payload.last != 0x0A {
            payload.append(0x0A)
        }
        try writeAll(payload)
    }

    public func close() async {
        closeSync()
    }

    public func closeSync() {
        stateLock.lock()
        guard !isClosed else {
            stateLock.unlock()
            return
        }
        isClosed = true
        stateLock.unlock()

        if closeOnDeinit {
            if readFD == writeFD {
                _ = Darwin.shutdown(readFD, SHUT_RDWR)
                _ = Darwin.close(readFD)
            } else {
                _ = Darwin.close(readFD)
                _ = Darwin.close(writeFD)
            }
        }
    }

    private func checkClosed() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isClosed
    }

    private func writeAll(_ data: Data) throws {
        if checkClosed() {
            throw TransportError.closed
        }

        writeLock.lock()
        defer { writeLock.unlock() }

        try data.withUnsafeBytes { rawBuffer in
            guard let basePtr = rawBuffer.baseAddress else { return }
            var totalWritten = 0
            let totalBytes = rawBuffer.count

            while totalWritten < totalBytes {
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
                    throw TransportError.writeFailed(err)
                } else {
                    throw TransportError.closed
                }
            }
        }
    }

    private static func isWhitespaceOnly(_ data: Data) -> Bool {
        data.allSatisfy { byte in
            byte == 0x20 || byte == 0x09 || byte == 0x0D || byte == 0x0A
        }
    }
}

/// Non-blocking stdio NDJSON transport reading `stdin` (`FileHandle.standardInput`) and writing `stdout` (`FileHandle.standardOutput`).
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
            label: "com.macp.transport.stdio"
        )
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
