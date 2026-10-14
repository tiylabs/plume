import Foundation
import PlumeKit

/// The helper's connection to its own Plume: find it, start it if needed, prove the credential,
/// then carry requests.
///
/// Rules the helper keeps, each because the alternative would surprise someone:
///
/// - **No credential, no launch.** Agent access is off by default; an unconfigured call must not
///   start Plume, run its first-launch setup and create a vault nobody asked for. `AUTH_FAILED` at
///   once.
/// - **Only its own app.** The app is the one the helper sits inside (`AgentInstallLocation`), never
///   one found by name. If another installed copy of the same profile already owns the socket, the
///   answer is `APP_INSTANCE_MISMATCH` — not a second writer.
/// - **Launched in the background.** LaunchServices with `open -g`: no activation, no panel, no
///   stolen focus.
/// - **Never around the app.** If the app cannot be reached, the request fails with a reason; the
///   helper does not fall back to reading or writing files itself — it could not, under TCC, and it
///   would bypass every version check if it could.
/// - **Blocked is not absent.** A sandboxed shell refusing the socket (`EPERM`/`EACCES`) is
///   `CONNECTION_BLOCKED`, with advice, rather than a launch attempt that cannot succeed either.
public final class AgentClient: @unchecked Sendable {

    public typealias Launcher = @Sendable (URL) -> Bool

    public let location: AgentInstallLocation
    public let runtime: AgentRuntimeDirectory
    private let token: String?
    private let clientLabel: String?
    private let launcher: Launcher

    private let lock = NSLock()
    private let connectionLock = NSLock()
    private var socket: IPCSocket?
    private var pending: [String: Pending] = [:]
    private var counter = 0
    private var _permission: AgentPermission?

    /// Called on the reader thread when the app reports a permission change.
    public var onPermissionChanged: (@Sendable (AgentPermission) -> Void)?

    private final class Pending: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var result: Result<JSONValue, AgentFailure>?
    }

    public init(
        location: AgentInstallLocation,
        runtime: AgentRuntimeDirectory? = nil,
        token: String?,
        clientLabel: String?,
        launcher: @escaping Launcher = AgentClient.openInBackground
    ) {
        self.location = location
        self.runtime = runtime ?? .standard(profile: location.profile)
        self.token = token
        self.clientLabel = clientLabel
        self.launcher = launcher
    }

    /// The permission the app last reported, or nil before the first connection.
    public var permission: AgentPermission? { lock.withLock { _permission } }

    // MARK: - Connecting

    /// Connects (launching the app if it is not running) unless already connected.
    @discardableResult
    public func connect() throws -> AgentPermission {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        if let socket = lock.withLock({ self.socket }), let permission = self.permission {
            _ = socket
            return permission
        }
        guard let token, !token.isEmpty else {
            throw AgentFailure(
                .authFailed,
                "no credential: set \(AgentAPI.tokenEnvironmentKey) to the value shown in Plume's settings (Connect Your Agent)"
            )
        }

        let deadline = Date().addingTimeInterval(AgentLimits.readyTimeout)
        var launched = false
        var lastFailure = AgentFailure(.appNotReady, "Plume did not answer in time")

        while true {
            switch openSocket() {
            case .success(let socket):
                do {
                    let permission = try handshake(socket, token: token)
                    return permission
                } catch let failure as AgentFailure where failure.code == .appNotReady {
                    lastFailure = failure
                } catch {
                    throw error
                }
            case .failure(.blocked(let code)):
                throw AgentFailure(
                    .connectionBlocked,
                    "the agent's sandbox refused the connection to Plume (\(String(cString: strerror(code)))). Start plume-agent as an MCP server from the agent's configuration, or allow local sockets in the agent's sandbox settings",
                    details: ["socket": runtime.socketURL.path]
                )
            case .failure(.foreignPath):
                throw AgentFailure(.connectionBlocked, "something that is not Plume's socket is at \(runtime.socketURL.path)")
            case .failure(.notRunning):
                if let mismatch = otherOwner() { throw mismatch }
                if !launched, !AgentOwnerLock.isHeld(runtime) {
                    launched = true
                    guard launcher(location.appBundle) else {
                        throw AgentFailure(
                            .connectionBlocked,
                            "could not start \(location.profile.displayName) at \(location.appBundle.path); the agent's sandbox may forbid launching apps — open Plume yourself and retry"
                        )
                    }
                }
            case .failure(.other(let code)):
                lastFailure = AgentFailure(.appNotReady, "cannot reach Plume: \(String(cString: strerror(code)))")
            }
            guard Date() < deadline else { throw lastFailure }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    private enum OpenError: Error {
        case notRunning
        case blocked(Int32)
        case foreignPath
        case other(Int32)
    }

    private func openSocket() -> Result<IPCSocket, OpenError> {
        do {
            try runtime.verifyDirectory()
        } catch let failure as AgentFailure where failure.code == .connectionBlocked {
            return .failure(.foreignPath)
        } catch {
            return .failure(.notRunning)
        }
        switch runtime.socketStatus() {
        case .absent: return .failure(.notRunning)
        case .foreign: return .failure(.foreignPath)
        case .ours: break
        }
        switch IPCSocket.connect(to: runtime.socketURL) {
        case .success(let socket): return .success(socket)
        case .failure(.notRunning): return .failure(.notRunning)
        case .failure(.blocked(let code)): return .failure(.blocked(code))
        case .failure(.other(let code)): return .failure(.other(code))
        }
    }

    /// Another installed copy of this profile holds the socket.
    private func otherOwner() -> AgentFailure? {
        guard AgentOwnerLock.isHeld(runtime),
              let data = try? Data(contentsOf: runtime.ownerURL),
              let owner = try? AgentJSON.decoder.decode(AgentOwnerRecord.self, from: data),
              owner.instance != location.instance
        else { return nil }
        return AgentFailure(
            .appInstanceMismatch,
            "another installed copy of \(location.profile.displayName) is running (\(owner.bundlePath)); copy the agent configuration from that copy's settings, or quit it",
            details: ["running_app": owner.bundlePath]
        )
    }

    private func handshake(_ socket: IPCSocket, token: String) throws -> AgentPermission {
        try socket.write(IPCMessage.hello(
            profile: location.profile.runtimeKey, instance: location.instance,
            appVersion: location.appVersion, token: token, clientLabel: clientLabel
        ))
        guard let frame = try socket.readFrame(timeout: AgentLimits.readyTimeout) else {
            throw AgentFailure(.appNotReady, "Plume closed the connection during the handshake")
        }
        let reply = try IPCMessage.decode(frame)
        switch reply.type {
        case .welcome:
            guard reply.ipcMajor == AgentAPI.ipcMajorVersion, let permission = reply.permission else {
                throw AgentFailure(.protocolMismatch, "Plume answered with an IPC version this helper does not speak; restart the agent")
            }
            lock.withLock {
                self.socket = socket
                self._permission = permission
            }
            let thread = Thread { [weak self] in self?.readLoop(socket) }
            thread.name = "plume-agent.reader"
            thread.start()
            return permission
        case .error:
            throw reply.error ?? AgentFailure(.protocolMismatch, "Plume refused the connection")
        default:
            throw AgentFailure(.protocolMismatch, "unexpected \(reply.type.rawValue) during the handshake")
        }
    }

    // MARK: - Requests

    /// One request, blocking until its answer, a timeout or a lost connection. Thread-safe; any
    /// number may be in flight at once over the one connection.
    public func call(_ tool: AgentTool, params: JSONValue, timeout: TimeInterval? = nil, id: String? = nil) throws -> JSONValue {
        try connect()
        let pending = Pending()
        let (socket, requestID) = lock.withLock { () -> (IPCSocket?, String) in
            counter += 1
            let requestID = id ?? "r\(counter)"
            self.pending[requestID] = pending
            return (self.socket, requestID)
        }
        guard let socket else { throw IPCSocket.connectionLost() }
        do {
            try socket.write(IPCMessage.request(id: requestID, method: tool, params: params))
        } catch {
            _ = lock.withLock { self.pending.removeValue(forKey: requestID) }
            dropConnection(socket)
            throw error
        }

        let wait = timeout ?? Self.timeout(for: tool, params: params)
        guard pending.done.wait(timeout: .now() + wait) == .success, let result = pending.result else {
            _ = lock.withLock { self.pending.removeValue(forKey: requestID) }
            throw Self.describeTimeout(tool, params: params)
        }
        switch result {
        case .success(let value): return value
        case .failure(let failure):
            throw failure.forRequest(params["request_id"]?.stringValue, state: nil)
        }
    }

    /// Asks the app not to start a request that has not begun. A write already prepared finishes.
    public func cancel(id: String) {
        let (socket, waiter) = lock.withLock { (self.socket, self.pending.removeValue(forKey: id)) }
        try? socket?.write(IPCMessage.cancel(id: id))
        if let waiter {
            waiter.result = .failure(AgentFailure(.requestTimeout, "cancelled"))
            waiter.done.signal()
        }
    }

    public static func timeout(for tool: AgentTool, params: JSONValue) -> TimeInterval {
        if tool == .readNote, params["download"] == .bool(true) { return AgentLimits.downloadTimeout }
        return AgentLimits.requestTimeout
    }

    /// A timeout says what is known: for a write, that it may have happened, and how to find out.
    public static func describeTimeout(_ tool: AgentTool, params: JSONValue) -> AgentFailure {
        guard tool.writes, tool != .getOperation else {
            return AgentFailure(.requestTimeout, "Plume did not answer in time")
        }
        let requestID = params["request_id"]?.stringValue
        return AgentFailure(
            .requestTimeout,
            "Plume did not confirm the write in time. It may still have been saved: call get_operation with the same request_id before trying again",
            retryable: true,
            requestID: requestID
        )
    }

    private func readLoop(_ socket: IPCSocket) {
        while true {
            guard let frame = try? socket.readFrame(), let message = try? IPCMessage.decode(frame) else {
                dropConnection(socket)
                return
            }
            switch message.type {
            case .response:
                guard let id = message.id else { continue }
                let waiter = lock.withLock { pending.removeValue(forKey: id) }
                if let error = message.error {
                    waiter?.result = .failure(error)
                } else {
                    waiter?.result = .success(message.result ?? .null)
                }
                waiter?.done.signal()
            case .event where message.event == "permission_changed":
                if let permission = message.permission {
                    lock.withLock { _permission = permission }
                    onPermissionChanged?(permission)
                }
            case .error:
                // The app refused something about the connection itself (a revoke, a protocol
                // error); everything waiting gets that answer.
                failAll(message.error ?? IPCSocket.connectionLost(), socket: socket)
                return
            default:
                continue
            }
        }
    }

    private func dropConnection(_ socket: IPCSocket) {
        failAll(IPCSocket.connectionLost(), socket: socket)
    }

    private func failAll(_ failure: AgentFailure, socket: IPCSocket) {
        let waiters = lock.withLock { () -> [Pending] in
            guard self.socket === socket else { return [] }
            self.socket = nil
            self._permission = nil
            let all = Array(pending.values)
            pending.removeAll()
            return all
        }
        socket.close()
        for waiter in waiters {
            waiter.result = .failure(failure)
            waiter.done.signal()
        }
    }

    // MARK: - Launching

    /// LaunchServices, in the background: `open -g` never activates the app or brings a window up.
    public static let openInBackground: Launcher = { bundle in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
