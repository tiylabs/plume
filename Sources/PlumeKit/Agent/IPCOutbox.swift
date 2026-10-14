import Foundation

/// One connection's outgoing frames, sent in order from a queue of their own.
///
/// The app answers requests from the main actor, and a send blocks until the peer has taken the
/// bytes. So a helper that stopped reading held the main thread for as long as it stayed stopped,
/// once a reply outgrew the socket's buffer — and ⌃Z on a terminal agent stops its whole process
/// group, helper included. Measured: a 1 MiB reply to a client that did not read delayed a 50 ms
/// main-thread timer until the client was closed. Permission broadcasts from Settings took the
/// same path.
///
/// So `send` only encodes and enqueues. Each frame leaves under the socket's send deadline, and what
/// may wait unsent is bounded; a peer that misses either is disconnected, not waited for. Its helper
/// reconnects, and a write it was waiting on can be looked up with `get_operation`.
public final class IPCOutbox: @unchecked Sendable {
    private let socket: IPCSocket
    private let queue = DispatchQueue(label: "com.tiylabs.plume.cli-outbox")
    private let maxQueuedBytes: Int
    private let lock = NSLock()
    private var queuedBytes = 0

    public init(socket: IPCSocket, maxQueuedBytes: Int = AgentLimits.ipcMaxQueuedBytes) {
        self.socket = socket
        self.maxQueuedBytes = maxQueuedBytes
    }

    /// Queues `message` and returns at once.
    public func send<T: Encodable>(_ message: T) {
        // Unencodable or over the frame limit: dropped, as a direct write's error always was. The
        // connection itself is fine, and the waiting request ends at its own timeout.
        guard let data = try? AgentJSON.encoder.encode(message), data.count <= AgentLimits.ipcMaxFrameBytes else { return }
        let admitted = lock.withLock { () -> Bool in
            guard queuedBytes + data.count <= maxQueuedBytes else { return false }
            queuedBytes += data.count
            return true
        }
        guard admitted else {
            socket.shutdown()
            return
        }
        queue.async { [self] in
            defer { lock.withLock { queuedBytes -= data.count } }
            do {
                try socket.writeFrame(data)
            } catch {
                socket.shutdown()
            }
        }
    }

    /// Shuts the connection down once everything queued before this has been sent, or has missed its
    /// deadline. A revoke broadcasts `permission_changed` and then disconnects; shutting down at once
    /// would drop that last frame still in the queue, and the helper would see only a lost
    /// connection instead of being told its tools changed.
    public func shutdownAfterQueued() {
        queue.async { [socket] in socket.shutdown() }
    }
}
