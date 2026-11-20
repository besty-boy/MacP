import Darwin
import Foundation

/// Resolves the local-user Unix domain socket path used between `MacP.app` and `MacP --stdio`.
public enum MacPSocketPath {
    /// Maximum UTF-8 byte length safely fitting into `sockaddr_un.sun_path` (104 bytes including NUL).
    private static let maxSunPathBytes = 100

    public static var defaultPath: String {
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first {
            let candidate = appSupport
                .appendingPathComponent("MacP", isDirectory: true)
                .appendingPathComponent("macp.sock")
                .path
            if candidate.utf8.count <= maxSunPathBytes {
                return candidate
            }
        }
        return "/tmp/macp-\(getuid()).sock"
    }

    fileprivate static func makeAddress(path: String) throws -> (sockaddr_un, socklen_t) {
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            throw TransportError.socketPathTooLong(path)
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: UInt8.self, capacity: capacity) { bytesPtr in
                for i in 0..<pathBytes.count {
                    bytesPtr[i] = pathBytes[i]
                }
                bytesPtr[pathBytes.count] = 0
            }
        }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return (addr, length)
    }
}

/// Local Unix Domain Socket server embedded inside `MacP.app` (Menu Bar daemon).
/// Secures the socket to `0600` (current macOS user only).
public final class UnixSocketServer: @unchecked Sendable {
    public let socketPath: String
    private let stateLock = NSLock()
    private let acceptQueue = DispatchQueue(label: "com.macp.unix-socket.accept", qos: .userInitiated)
    private var listenFD: Int32 = -1
    private var isRunning = false
    private var activeConnections: [UUID: FileDescriptorTransport] = [:]

    public init(socketPath: String = MacPSocketPath.defaultPath) {
        self.socketPath = socketPath
        _ = signal(SIGPIPE, SIG_IGN)
    }

    deinit {
        stopSync()
    }

    /// Starts listening for `--stdio` bridge clients on the local Unix domain socket.
    public func start(
        onClientConnected: @escaping @Sendable (UUID, FileDescriptorTransport) async -> Void
    ) throws {
        stateLock.lock()
        if isRunning {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        let parentDir = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Remove stale socket file if it exists and is not actively served.
        if FileManager.default.fileExists(atPath: socketPath) {
            if !Self.canConnect(path: socketPath) {
                _ = Darwin.unlink(socketPath)
            } else {
                // Another MacP instance is actively listening on this socket.
                throw TransportError.bindFailed(EADDRINUSE, socketPath)
            }
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TransportError.socketCreationFailed(errno)
        }

        var (addr, addrLen) = try MacPSocketPath.makeAddress(path: socketPath)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, addrLen)
            }
        }

        guard bindResult == 0 else {
            let err = errno
            _ = Darwin.close(fd)
            throw TransportError.bindFailed(err, socketPath)
        }

        // Restrict socket permissions strictly to the current local user (rw-------).
        _ = Darwin.chmod(socketPath, 0o600)

        guard Darwin.listen(fd, 16) == 0 else {
            let err = errno
            _ = Darwin.close(fd)
            _ = Darwin.unlink(socketPath)
            throw TransportError.listenFailed(err)
        }

        stateLock.lock()
        self.listenFD = fd
        self.isRunning = true
        stateLock.unlock()

        DiagnosticLog.write("UnixSocketServer listening on \(socketPath)")

        acceptQueue.async { [weak self] in
            self?.acceptLoop(listenFD: fd, onClientConnected: onClientConnected)
        }
    }

    public func stop() {
        stopSync()
    }

    private func stopSync() {
        stateLock.lock()
        guard isRunning else {
            stateLock.unlock()
            return
        }
        isRunning = false
        let fd = listenFD
        listenFD = -1
        let connections = Array(activeConnections.values)
        activeConnections.removeAll()
        stateLock.unlock()

        if fd >= 0 {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            _ = Darwin.close(fd)
        }

        for connection in connections {
            connection.closeSync()
        }

        _ = Darwin.unlink(socketPath)
        DiagnosticLog.write("UnixSocketServer stopped (\(socketPath))")
    }

    private func acceptLoop(
        listenFD: Int32,
        onClientConnected: @escaping @Sendable (UUID, FileDescriptorTransport) async -> Void
    ) {
        while checkRunning() {
            var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&pfd, 1, 150)

            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 {
                continue
            }
            if (pfd.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0 {
                break
            }

            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                if !checkRunning() { break }
                continue
            }

            var noSigPipe: Int32 = 1
            _ = Darwin.setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            let clientID = UUID()
            let transport = FileDescriptorTransport(
                readFD: clientFD,
                writeFD: clientFD,
                closeOnDeinit: true,
                label: "com.macp.unix-socket.client.\(clientID.uuidString.prefix(8))"
            )

            stateLock.lock()
            activeConnections[clientID] = transport
            stateLock.unlock()

            Task { [weak self] in
                await onClientConnected(clientID, transport)
                self?.removeConnection(id: clientID)
                await transport.close()
            }
        }
    }

    private func removeConnection(id: UUID) {
        stateLock.lock()
        activeConnections.removeValue(forKey: id)
        stateLock.unlock()
    }

    private func checkRunning() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isRunning
    }

    /// Attempts a quick connect probe to check whether a server is actively listening on `path`.
    public static func canConnect(path: String) -> Bool {
        guard let transport = try? UnixSocketClient.connect(path: path) else {
            return false
        }
        transport.closeSync()
        return true
    }
}

/// Connects to an active `UnixSocketServer` and returns a bidirectional NDJSON transport.
public enum UnixSocketClient {
    public static func connect(path: String = MacPSocketPath.defaultPath) throws -> FileDescriptorTransport {
        _ = signal(SIGPIPE, SIG_IGN)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TransportError.socketCreationFailed(errno)
        }

        var (addr, addrLen) = try MacPSocketPath.makeAddress(path: path)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, addrLen)
            }
        }

        guard result == 0 else {
            let err = errno
            _ = Darwin.close(fd)
            throw TransportError.connectFailed(err, path)
        }

        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        return FileDescriptorTransport(
            readFD: fd,
            writeFD: fd,
            closeOnDeinit: true,
            label: "com.macp.unix-socket.relay"
        )
    }

    /// Relays NDJSON JSON-RPC lines bidirectionally between a local stdio transport and the MacP app socket.
    public static func relay(
        stdio: any NDJSONTransport,
        socket: any NDJSONTransport
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await line in stdio.incomingLines() {
                    do {
                        try await socket.sendLine(line)
                    } catch {
                        break
                    }
                }
                await socket.close()
            }

            group.addTask {
                for await line in socket.incomingLines() {
                    do {
                        try await stdio.sendLine(line)
                    } catch {
                        break
                    }
                }
                await stdio.close()
            }

            await group.next()
            group.cancelAll()
        }
    }
}
