import Darwin
import Foundation

/// The app's end of the agent socket: owns the path, checks each connection, and hands requests on.
///
/// What it decides itself, on its own threads and without waiting for the main thread:
///
/// - whether this process may own the socket at all (the profile's owner lock);
/// - whether a connection is from this user (`getpeereid`), speaks this IPC major version, belongs to
///   this installed copy, and carries the current credential;
/// - whether the app is ready — answered from a flag, because at launch the main thread may be
///   sitting in the vault chooser's modal loop, and a helper must hear `VAULT_UNAVAILABLE` in
///   milliseconds rather than time out.
///
/// What it does not decide: anything about notes. A request is passed to `onRequest` with a reply
/// closure, and the coordinator answers it from the main actor. The reply, like a broadcast, only
/// queues the frame on the connection's `IPCOutbox`, so no peer can hold the main thread.
public final class AgentSocketServer: @unchecked Sendable {

    public struct Identity: Sendable {
        public var profile: BuildProfile
        public var instance: String
        public var appVersion: String
        public var bundlePath: String

        public init(profile: BuildProfile, instance: String, appVersion: String, bundlePath: String) {
            self.profile = profile
            self.instance = instance
            self.appVersion = appVersion
            self.bundlePath = bundlePath
        }
    }

    public enum Readiness: Sendable, Equatable {
        case starting
        case vaultUnavailable
        case ready
    }

    /// What a connection authenticated as. Requests carry it so each one can be re-checked against
    /// the current generation and permission — a revoke takes effect on the next request.
    public struct Client: Sendable, Equatable {
        public var connectionID: UUID
        public var generation: String
        public var clientLabel: String?
    }

    public struct Grant: Sendable {
        public var permission: AgentPermission
        public var generation: String

        public init(permission: AgentPermission, generation: String) {
            self.permission = permission
            self.generation = generation
        }
    }

    public typealias Reply = @Sendable (Result<JSONValue, AgentFailure>) -> Void

    /// Checks a credential: the grant, or why not. Called on a connection thread.
    public var authenticate: @Sendable (String?) -> Result<Grant, AgentFailure> = { _ in
        .failure(AgentFailure(.accessDisabled, "agent access is off"))
    }
    public var onRequest: @Sendable (Client, String, String, JSONValue, @escaping Reply) -> Void = { _, _, _, _, reply in
        reply(.failure(AgentFailure(.appNotReady, "not ready")))
    }
    public var onCancel: @Sendable (Client, String) -> Void = { _, _ in }

    public let runtime: AgentRuntimeDirectory
    public let identity: Identity

    private let lock = NSLock()
    private var _readiness: Readiness = .starting
    private var ownerLock: AgentOwnerLock?
    private var listenFD: Int32 = -1
    private var connections: [UUID: Connection] = [:]
    private var running = false
    private let sendTimeout: TimeInterval

    private struct Connection {
        let socket: IPCSocket
        let outbox: IPCOutbox
    }

    public init(
        runtime: AgentRuntimeDirectory, identity: Identity, sendTimeout: TimeInterval = AgentLimits.ipcSendTimeout
    ) {
        self.runtime = runtime
        self.identity = identity
        self.sendTimeout = sendTimeout
    }

    public var readiness: Readiness {
        get { lock.withLock { _readiness } }
        set { lock.withLock { _readiness = newValue } }
    }

    public var isRunning: Bool { lock.withLock { running } }

    // MARK: - Lifecycle

    public enum StartError: Error, Equatable {
        /// Another live process of this profile already owns the socket.
        case ownedElsewhere
        /// Something that is not our socket sits at the path; it is left alone.
        case pathOccupied
        case failed(String)
    }

    public func start() throws {
        do {
            try runtime.prepare()
        } catch {
            throw StartError.failed(String(describing: error))
        }
        guard let owner = AgentOwnerLock.acquire(runtime) else { throw StartError.ownedElsewhere }

        // Holding the owner lock means no live process is serving this path, so a socket file left
        // there is a crashed run's. Ours to remove — but only if it is a socket and ours.
        switch runtime.socketStatus() {
        case .absent: break
        case .ours: unlink(runtime.socketURL.path)
        case .foreign: throw StartError.pathOccupied
        }

        let fd: Int32
        do {
            fd = try IPCSocket.listen(at: runtime.socketURL)
        } catch {
            throw StartError.failed(String(describing: error))
        }

        let record = AgentOwnerRecord(
            pid: getpid(), instance: identity.instance, appVersion: identity.appVersion,
            bundlePath: identity.bundlePath
        )
        try? DurableFile.write(AgentJSON.prettyEncoder.encode(record), to: runtime.ownerURL)

        lock.withLock {
            ownerLock = owner
            listenFD = fd
            running = true
        }
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "plume.agent.accept"
        thread.start()
    }

    /// Stops listening, closes every connection, removes the socket and gives up ownership.
    public func stop() {
        let (fd, open) = lock.withLock { () -> (Int32, [IPCSocket]) in
            running = false
            let fd = listenFD
            listenFD = -1
            let open = connections.values.map(\.socket)
            connections.removeAll()
            return (fd, open)
        }
        guard fd >= 0 else { return }
        unlink(runtime.socketURL.path)
        unlink(runtime.ownerURL.path)
        Darwin.shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        for socket in open { socket.close() }
        lock.withLock { ownerLock = nil }
    }

    /// Queues a frame to every authenticated connection — permission changes.
    public func broadcast(_ message: IPCMessage) {
        let open = lock.withLock { Array(connections.values) }
        for connection in open { connection.outbox.send(message) }
    }

    /// Closes every connection; a revoke uses this so nothing keeps working on the old credential.
    /// Each closes behind the frames already queued for it, so a broadcast just before still lands.
    /// Requests are re-checked against the credential on arrival, so the wait opens nothing up.
    public func disconnectAll() {
        let open = lock.withLock { () -> [Connection] in
            let open = Array(connections.values)
            connections.removeAll()
            return open
        }
        for connection in open { connection.outbox.shutdownAfterQueued() }
    }

    // MARK: - Connections

    private func acceptLoop(_ fd: Int32) {
        while isRunning {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            let socket = IPCSocket(fd: client, sendTimeout: sendTimeout)
            guard socket.peerUID() == getuid() else {
                socket.close()
                continue
            }
            let thread = Thread { [weak self] in self?.serve(socket) }
            thread.name = "plume.agent.connection"
            thread.start()
        }
    }

    private func serve(_ socket: IPCSocket) {
        defer { socket.close() }
        guard let (client, outbox) = handshake(socket) else { return }
        defer { _ = lock.withLock { connections.removeValue(forKey: client.connectionID) } }

        while true {
            let frame: Data?
            do {
                frame = try socket.readFrame()
            } catch {
                return
            }
            guard let frame else { return }

            let message: IPCMessage
            do {
                message = try IPCMessage.decode(frame)
            } catch let failure as AgentFailure {
                try? socket.write(IPCMessage.failure(failure))
                return
            } catch {
                return
            }

            switch message.type {
            case .request:
                guard let id = message.id, let method = message.method else {
                    try? socket.write(IPCMessage.failure(AgentFailure(.protocolMismatch, "request without id or method")))
                    return
                }
                onRequest(client, id, method, message.params ?? .object([:])) { result in
                    outbox.send(IPCMessage.response(id: id, result: result))
                }
            case .cancel:
                if let id = message.id { onCancel(client, id) }
            default:
                try? socket.write(IPCMessage.failure(AgentFailure(.protocolMismatch, "unexpected \(message.type.rawValue) frame")))
                return
            }
        }
    }

    private func handshake(_ socket: IPCSocket) -> (Client, IPCOutbox)? {
        func refuse(_ failure: AgentFailure) -> (Client, IPCOutbox)? {
            try? socket.write(IPCMessage.failure(failure))
            return nil
        }

        guard let frame = try? socket.readFrame(timeout: AgentLimits.readyTimeout),
              let hello = try? IPCMessage.decode(frame), hello.type == .hello
        else { return refuse(AgentFailure(.protocolMismatch, "expected a hello frame")) }

        guard hello.ipcMajor == AgentAPI.ipcMajorVersion else {
            return refuse(AgentFailure(
                .protocolMismatch,
                "the helper speaks IPC version \(hello.ipcMajor ?? 0) and Plume speaks \(AgentAPI.ipcMajorVersion); restart the agent after updating Plume",
                details: ["app_version": identity.appVersion]
            ))
        }
        guard hello.profile == identity.profile.runtimeKey, hello.instance == identity.instance else {
            return refuse(AgentFailure(
                .appInstanceMismatch,
                "another installed copy of \(identity.profile.displayName) is running (\(identity.bundlePath)); copy the agent configuration from that copy's settings",
                details: ["running_app": identity.bundlePath]
            ))
        }

        let grant: Grant
        switch authenticate(hello.token) {
        case .success(let value): grant = value
        case .failure(let failure): return refuse(failure)
        }

        switch readiness {
        case .starting:
            return refuse(AgentFailure(.appNotReady, "Plume is still starting"))
        case .vaultUnavailable:
            return refuse(AgentFailure(
                .vaultUnavailable,
                "Plume cannot find its notes folder and is asking the user to choose one"
            ))
        case .ready:
            break
        }

        let client = Client(connectionID: UUID(), generation: grant.generation, clientLabel: hello.clientLabel)
        let outbox = IPCOutbox(socket: socket)
        // Registered and welcomed under one lock, so a broadcast either misses this connection or
        // queues behind the welcome — the helper reads anything before it as a broken handshake.
        lock.withLock {
            connections[client.connectionID] = Connection(socket: socket, outbox: outbox)
            outbox.send(IPCMessage.welcome(
                profile: identity.profile.runtimeKey, instance: identity.instance,
                appVersion: identity.appVersion, permission: grant.permission
            ))
        }
        return (client, outbox)
    }
}
