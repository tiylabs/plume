import Darwin
import Foundation

/// One end of the helper ⇄ app connection: a Unix domain stream socket carrying length-prefixed
/// JSON frames.
///
/// Framing is a 4-byte big-endian length, then that many bytes of JSON. Length-prefixed rather than
/// newline-delimited so a note body never has to be scanned for a delimiter, and so an oversized
/// frame is refused from its header before a byte of it is buffered.
///
/// Blocking I/O with a per-call deadline. The helper is a short-lived process with one connection;
/// the app runs each connection on its own thread. Neither needs an event loop, and blocking calls
/// with `poll` deadlines are the shape that is easiest to get right.
public final class IPCSocket: @unchecked Sendable {
    public let fd: Int32
    /// How long one frame may take to leave, or nil to wait as long as the peer takes. The app sets
    /// it on every connection it accepts (`IPCOutbox` says why); the helper's end waits.
    public let sendTimeout: TimeInterval?
    private let writeLock = NSLock()
    private var closed = false
    private let stateLock = NSLock()

    public init(fd: Int32, sendTimeout: TimeInterval? = nil) {
        self.fd = fd
        self.sendTimeout = sendTimeout
        var on: Int32 = 1
        // A peer that vanished must not kill this process with SIGPIPE.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        if let sendTimeout {
            // One `send` blocks at most this slice, so `writeFrame` can check its deadline between
            // calls. A send-only timeout: the connection thread's reads still block as before.
            // (`MSG_DONTWAIT` after a `POLLOUT` is not enough: measured on macOS 27, a send of a
            // 2 MiB frame on a Unix stream socket with that flag still blocked until the peer read.)
            let slice = min(sendTimeout, 0.25)
            var limit = timeval(tv_sec: Int(slice), tv_usec: Int32((slice - slice.rounded(.down)) * 1_000_000))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    deinit { close() }

    /// Shut down first, so a send blocked on this socket in another thread fails at once and lets go
    /// of the write lock; then release the descriptor under that lock. A send can then never reach
    /// the number after it has been reused for another file — which, with replies sent from a queue
    /// of their own (`IPCOutbox`), a send still queued when the connection ends would otherwise do.
    public func close() {
        let first = stateLock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        guard first else { return }
        Darwin.shutdown(fd, SHUT_RDWR)
        writeLock.withLock { _ = Darwin.close(fd) }
    }

    /// Unblocks a reader in another thread without releasing the descriptor yet.
    public func shutdown() {
        Darwin.shutdown(fd, SHUT_RDWR)
    }

    // MARK: - Frames

    public func writeFrame(_ data: Data) throws {
        guard data.count <= AgentLimits.ipcMaxFrameBytes else {
            throw AgentFailure(.contentTooLarge, "message exceeds \(AgentLimits.ipcMaxFrameBytes) bytes")
        }
        var length = UInt32(data.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(data)
        let deadline = sendTimeout.map { Date().addingTimeInterval($0) }
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !stateLock.withLock({ closed }) else { throw IPCSocket.connectionLost() }
        try frame.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                // A frame that misses its deadline may be half sent; the caller must drop the
                // connection, because the stream cannot be resumed mid-frame.
                if let deadline, deadline.timeIntervalSinceNow <= 0 { throw IPCSocket.sendTimedOut() }
                let sent = Darwin.send(fd, buffer.baseAddress! + offset, buffer.count - offset, 0)
                if sent < 0 {
                    // EAGAIN: a `SO_SNDTIMEO` slice ran out with nothing taken.
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw IPCSocket.connectionLost()
                }
                offset += sent
            }
        }
    }

    public func write<T: Encodable>(_ value: T) throws {
        try writeFrame(AgentJSON.encoder.encode(value))
    }

    /// The next frame, or nil at a clean end of stream. `timeout` nil waits indefinitely.
    public func readFrame(timeout: TimeInterval? = nil) throws -> Data? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        guard let header = try readExactly(4, deadline: deadline, allowEOF: true) else { return nil }
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length <= UInt32(AgentLimits.ipcMaxFrameBytes) else {
            throw AgentFailure(.protocolMismatch, "frame of \(length) bytes exceeds the limit")
        }
        guard length > 0 else { return Data() }
        return try readExactly(Int(length), deadline: deadline, allowEOF: false)
    }

    private func readExactly(_ count: Int, deadline: Date?, allowEOF: Bool) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { throw AgentFailure(.requestTimeout, "no answer from Plume in time") }
                var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&poller, 1, Int32(min(remaining * 1000, Double(Int32.max))))
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw IPCSocket.connectionLost()
                }
                if ready == 0 { throw AgentFailure(.requestTimeout, "no answer from Plume in time") }
            }
            let received = data.withUnsafeMutableBytes { buffer in
                Darwin.recv(fd, buffer.baseAddress! + offset, count - offset, 0)
            }
            if received == 0 {
                if allowEOF, offset == 0 { return nil }
                throw IPCSocket.connectionLost()
            }
            if received < 0 {
                if errno == EINTR { continue }
                throw IPCSocket.connectionLost()
            }
            offset += received
        }
        return data
    }

    public static func connectionLost() -> AgentFailure {
        AgentFailure(.requestTimeout, "the connection to Plume closed before an answer arrived", retryable: true)
    }

    static func sendTimedOut() -> AgentFailure {
        AgentFailure(.requestTimeout, "the other end stopped reading; the connection is closed", retryable: true)
    }

    // MARK: - Connecting and listening

    /// The peer's user ID, from the kernel. A connection from another user is refused outright.
    public func peerUID() -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return uid
    }

    public enum ConnectError: Error, Equatable {
        /// Nothing listening: no socket file, or a stale one.
        case notRunning
        /// The sandbox or a permission refused the connection (`EPERM` / `EACCES`).
        case blocked(Int32)
        case other(Int32)
    }

    public static func connect(to url: URL) -> Result<IPCSocket, ConnectError> {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .failure(errno == EPERM || errno == EACCES ? .blocked(errno) : .other(errno))
        }
        var address = sockaddr_un()
        guard fill(&address, path: url.path) else {
            Darwin.close(fd)
            return .failure(.other(ENAMETOOLONG))
        }
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            let code = errno
            Darwin.close(fd)
            switch code {
            case ENOENT, ECONNREFUSED: return .failure(.notRunning)
            case EPERM, EACCES: return .failure(.blocked(code))
            default: return .failure(.other(code))
            }
        }
        return .success(IPCSocket(fd: fd))
    }

    /// Binds and listens at `url`, `0600`. The caller has already established it owns the path.
    public static func listen(at url: URL) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DurableFile.posixError("socket", url) }
        var address = sockaddr_un()
        guard fill(&address, path: url.path) else {
            Darwin.close(fd)
            throw AgentFailure(.appNotReady, "socket path too long: \(url.path)")
        }
        // The umask decides the socket file's mode at bind; tighten it for exactly this call so the
        // socket is never, even for a moment, connectable by anyone else.
        let previous = umask(0o077)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previous)
        guard bound == 0 else {
            let error = DurableFile.posixError("bind", url)
            Darwin.close(fd)
            throw error
        }
        chmod(url.path, 0o600)
        guard Darwin.listen(fd, 16) == 0 else {
            let error = DurableFile.posixError("listen", url)
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    private static func fill(_ address: inout sockaddr_un, path: String) -> Bool {
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return true
    }
}
