import Darwin
import Foundation
import os

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

    fileprivate static func configureSocketFD(_ fd: Int32, nonBlocking: Bool) {
        // Prevent child processes (`shortcuts`, `osascript`, `mdfind`, `screencapture`) from inheriting IPC sockets.
        let fdFlags = Darwin.fcntl(fd, F_GETFD)
        if fdFlags >= 0 {
            _ = Darwin.fcntl(fd, F_SETFD, fdFlags | FD_CLOEXEC)
        }

        if nonBlocking {
            let statusFlags = Darwin.fcntl(fd, F_GETFL)
            if statusFlags >= 0 {
                _ = Darwin.fcntl(fd, F_SETFL, statusFlags | O_NONBLOCK)
            }
        }

        var noSigPipe: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }
}

/// Event-driven local Unix Domain Socket server embedded inside `MacP.app` (Menu Bar daemon).
/// - Zero idle CPU wakeups (`DispatchSourceRead` / kqueue instead of polling loops).
/// - Restricted to current macOS user (`0700` dir, `0600` socket, plus `getpeereid` UID check).
/// - Atomic `flock` instance guard preventing stale-socket races without phantom client probes.
public final class UnixSocketServer: @unchecked Sendable {
    public let socketPath: String
    private let lockFilePath: String

    private struct ServerState: @unchecked Sendable {
        var isRunning = false
        var listenFD: Int32 = -1
        var lockFD: Int32 = -1
        var acceptSource: DispatchSourceRead?
        var activeConnections: [UUID: FileDescriptorTransport] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: ServerState())
    private let acceptQueue = DispatchQueue(label: "com.macp.unix-socket.accept", qos: .userInitiated)

    public init(socketPath: String = MacPSocketPath.defaultPath) {
        self.socketPath = socketPath
        self.lockFilePath = socketPath + ".lock"
        _ = signal(SIGPIPE, SIG_IGN)
    }

    deinit {
        stopSync()
    }

    /// Starts listening for `--stdio` bridge clients on the local Unix domain socket.
    public func start(
        onClientConnected: @escaping @Sendable (UUID, FileDescriptorTransport) async -> Void
    ) throws {
        if state.withLock({ $0.isRunning }) {
            return
        }

        let parentDir = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // Acquire an atomic exclusive non-blocking advisory lock (`O_EXLOCK | O_NONBLOCK`) so a second MacP
        // instance fails cleanly without opening a phantom probe connection to the live server.
        let lockFD = Darwin.open(lockFilePath, O_CREAT | O_RDWR | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o600)
        if lockFD < 0 && (errno == EWOULDBLOCK || errno == EAGAIN) {
            throw TransportError.bindFailed(EADDRINUSE, socketPath)
        }

        // Remove stale socket file if it exists and is not actively served (e.g. legacy instance).
        if FileManager.default.fileExists(atPath: socketPath) {
            if !Self.canConnect(path: socketPath) {
                _ = Darwin.unlink(socketPath)
            } else {
                if lockFD >= 0 { _ = Darwin.close(lockFD) }
                throw TransportError.bindFailed(EADDRINUSE, socketPath)
            }
        }

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let err = errno
            if lockFD >= 0 { _ = Darwin.close(lockFD) }
            throw TransportError.socketCreationFailed(err)
        }

        MacPSocketPath.configureSocketFD(fd, nonBlocking: true)

        var (addr, addrLen) = try MacPSocketPath.makeAddress(path: socketPath)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, addrLen)
            }
        }

        guard bindResult == 0 else {
            let err = errno
            _ = Darwin.close(fd)
            if lockFD >= 0 { _ = Darwin.close(lockFD) }
            throw TransportError.bindFailed(err, socketPath)
        }

        // Restrict socket permissions strictly to the current local user (rw-------).
        _ = Darwin.chmod(socketPath, 0o600)

        guard Darwin.listen(fd, 32) == 0 else {
            let err = errno
            _ = Darwin.close(fd)
            _ = Darwin.unlink(socketPath)
            if lockFD >= 0 { _ = Darwin.close(lockFD) }
            throw TransportError.listenFailed(err)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptPendingClients(listenFD: fd, onClientConnected: onClientConnected)
        }
        source.setCancelHandler {
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            _ = Darwin.close(fd)
        }

        state.withLock { s in
            s.listenFD = fd
            s.lockFD = lockFD
            s.acceptSource = source
            s.isRunning = true
        }

        source.resume()
        DiagnosticLog.write("UnixSocketServer listening on \(socketPath) (event-driven kqueue)")
    }

    public func stop() {
        stopSync()
    }

    public func stopSync() {
        let teardown: (
            wasRunning: Bool,
            source: DispatchSourceRead?,
            lockFD: Int32,
            connections: [FileDescriptorTransport]
        ) = state.withLock { s in
            guard s.isRunning else {
                return (false, nil, -1, [])
            }
            s.isRunning = false
            s.listenFD = -1
            let src = s.acceptSource
            s.acceptSource = nil
            let lock = s.lockFD
            s.lockFD = -1
            let conns = Array(s.activeConnections.values)
            s.activeConnections.removeAll()
            return (true, src, lock, conns)
        }

        guard teardown.wasRunning else { return }

        teardown.source?.cancel()

        for connection in teardown.connections {
            connection.closeSync()
        }

        _ = Darwin.unlink(socketPath)
        if teardown.lockFD >= 0 {
            _ = Darwin.close(teardown.lockFD)
            _ = Darwin.unlink(lockFilePath)
        }
        DiagnosticLog.write("UnixSocketServer stopped (\(socketPath))")
    }

    private func acceptPendingClients(
        listenFD: Int32,
        onClientConnected: @escaping @Sendable (UUID, FileDescriptorTransport) async -> Void
    ) {
        let expectedUID = Darwin.geteuid()

        while state.withLock({ $0.isRunning }) {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD < 0 {
                let err = errno
                if err == EINTR { continue }
                if err == EAGAIN || err == EWOULDBLOCK { break }
                break
            }

            // Defense in depth: verify the connecting local process belongs to the exact same macOS user.
            var peerUID: uid_t = 0
            var peerGID: gid_t = 0
            guard Darwin.getpeereid(clientFD, &peerUID, &peerGID) == 0, peerUID == expectedUID else {
                _ = Darwin.close(clientFD)
                DiagnosticLog.write("Rejected Unix socket peer with unexpected UID")
                continue
            }

            MacPSocketPath.configureSocketFD(clientFD, nonBlocking: true)

            let clientID = UUID()
            let transport = FileDescriptorTransport(
                readFD: clientFD,
                writeFD: clientFD,
                closeOnDeinit: true,
                isNonBlocking: true,
                label: "com.macp.unix-socket.client.\(clientID.uuidString.prefix(8))"
            )

            state.withLock { s in
                s.activeConnections[clientID] = transport
            }

            Task { [weak self] in
                await onClientConnected(clientID, transport)
                self?.removeConnection(id: clientID)
                await transport.close()
            }
        }
    }

    private func removeConnection(id: UUID) {
        state.withLock { s in
            _ = s.activeConnections.removeValue(forKey: id)
        }
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

        // Keep connect synchronous, then switch the connected FD to non-blocking + CLOEXEC.
        MacPSocketPath.configureSocketFD(fd, nonBlocking: false)

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

        MacPSocketPath.configureSocketFD(fd, nonBlocking: true)

        return FileDescriptorTransport(
            readFD: fd,
            writeFD: fd,
            closeOnDeinit: true,
            isNonBlocking: true,
            label: "com.macp.unix-socket.relay"
        )
    }

    /// Relays NDJSON JSON-RPC lines bidirectionally between a local stdio transport and the MacP app socket.
    /// Exits promptly as soon as either side reaches EOF or disconnects.
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
            await socket.close()
            await stdio.close()
            group.cancelAll()
        }
    }
}
