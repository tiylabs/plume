import Foundation
import PlumeKit

/// What the MCP server and the CLI need from a connection to Plume. `AgentClient` is the real one.
public protocol AgentCalling: AnyObject, Sendable {
    var permission: AgentPermission? { get }
    var onPermissionChanged: (@Sendable (AgentPermission) -> Void)? { get set }
    @discardableResult func connect() throws -> AgentPermission
    func call(_ tool: AgentTool, params: JSONValue, timeout: TimeInterval?, id: String?) throws -> JSONValue
    func cancel(id: String)
}

extension AgentClient: AgentCalling {}

/// A minimal MCP server over stdio: newline-delimited JSON-RPC 2.0, tools only.
///
/// Implemented here rather than with an SDK — `Design/Notes/agent-integration-phase0.md` has the
/// comparison. The subset is what a tools-only server needs: `initialize`, `notifications/
/// initialized`, `ping`, `tools/list`, `tools/call`, `notifications/cancelled`, and the server's own
/// `notifications/tools/list_changed`. No resources, prompts, sampling or HTTP.
///
/// **stdout carries protocol messages and nothing else**; every diagnostic goes to stderr. A stray
/// line on stdout is a parse error in the client, and some clients drop the server for it.
///
/// Domain failures are tool results with `isError: true` and the stable code in the text and in
/// `structuredContent`; JSON-RPC errors are only for protocol problems (unknown method, malformed
/// message, unknown tool name).
public final class MCPServer: @unchecked Sendable {

    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let backend: any AgentCalling
    private let write: @Sendable (String) -> Void
    private let log: @Sendable (String) -> Void
    private let serverVersion: String
    private let work = DispatchQueue(label: "plume-cli.mcp.calls", attributes: .concurrent)
    private let inFlightGroup = DispatchGroup()

    private let lock = NSLock()
    private var protocolVersion = MCPServer.supportedProtocolVersions[0]
    private var initialized = false
    private var listedPermission: AgentPermission?
    private var calls: [String: String] = [:]    // JSON-RPC id → IPC id
    private var cancelled: Set<String> = []
    private var counter = 0
    /// The client's name from `initialize`, shown in Plume's recent writes.
    public private(set) var clientName: String?

    public init(
        backend: any AgentCalling,
        serverVersion: String,
        write: @escaping @Sendable (String) -> Void,
        log: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
    ) {
        self.backend = backend
        self.serverVersion = serverVersion
        self.write = write
        self.log = log
        backend.onPermissionChanged = { [weak self] permission in self?.permissionChanged(permission) }
    }

    /// Reads stdin until it closes, then waits for calls still running so their answers are sent.
    public func run(input: FileHandle = .standardInput) {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            guard buffer.count <= AgentLimits.ipcMaxFrameBytes else {
                send(error: -32600, "Request exceeds the message size limit", id: .null)
                return
            }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                handle(line: String(decoding: line, as: UTF8.self))
            }
        }
        if !buffer.isEmpty { handle(line: String(decoding: buffer, as: UTF8.self)) }
        inFlightGroup.wait()
    }

    /// Waits until every `tools/call` already started has answered. For tests and for EOF.
    public func waitForCalls() { inFlightGroup.wait() }

    // MARK: - Messages

    public func handle(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.utf8.count <= AgentLimits.ipcMaxFrameBytes else {
            send(error: -32600, "Request exceeds the message size limit", id: .null)
            return
        }
        guard let message = try? AgentJSON.decoder.decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            send(error: -32700, "Parse error", id: .null)
            return
        }
        guard case .object(let object) = message else {
            send(error: -32600, "Invalid Request: batches are not supported", id: .null)
            return
        }
        let id = object["id"]
        guard object["jsonrpc"] == .string("2.0"),
              object["params"] == nil || object["params"]?.objectValue != nil else {
            send(error: -32600, "Invalid JSON-RPC request", id: id ?? .null)
            return
        }
        if let id {
            switch id {
            case .string, .number: break
            default: send(error: -32600, "Invalid request id", id: .null); return
            }
        }
        guard let method = object["method"]?.stringValue else {
            // A response to something we sent; this server sends no requests, so there is none.
            if id == nil { send(error: -32600, "Invalid Request", id: .null) }
            return
        }
        let params = object["params"] ?? .object([:])

        guard let id, id != .null else {
            notification(method, params: params)
            return
        }

        guard method == "initialize" || method == "ping" || lock.withLock({ initialized }) else {
            send(error: -32600, "Initialize the connection first", id: id)
            return
        }
        switch method {
        case "initialize": initialize(id: id, params: params)
        case "ping": send(result: .object([:]), id: id)
        case "tools/list": listTools(id: id)
        case "tools/call": callTool(id: id, params: params)
        default: send(error: -32601, "Method not found: \(method)", id: id)
        }
    }

    private func notification(_ method: String, params: JSONValue) {
        switch method {
        case "notifications/initialized":
            lock.withLock { initialized = true }
        case "notifications/cancelled":
            guard let requestID = params["requestId"] else { return }
            let key = Self.key(requestID)
            let ipcID = lock.withLock { () -> String? in
                cancelled.insert(key)
                return calls[key]
            }
            if let ipcID { backend.cancel(id: ipcID) }
        default:
            break  // unknown notifications are ignored, as JSON-RPC requires
        }
    }

    private func initialize(id: JSONValue, params: JSONValue) {
        let requested = params["protocolVersion"]?.stringValue ?? ""
        let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
        lock.withLock {
            protocolVersion = version
            clientName = params["clientInfo"]?["name"]?.stringValue
        }
        send(result: .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object(["listChanged": .bool(true)])]),
            "serverInfo": .object(["name": .string("plume"), "title": .string("Plume"), "version": .string(serverVersion)]),
            "instructions": .string(MCPToolCatalog.serverInstructions),
        ]), id: id)
    }

    /// Only the tools this connection may use. If Plume cannot be reached the full list is offered
    /// and each call then explains why it failed (no credential, access off, app not reachable) —
    /// an empty list would leave the agent with no way to tell the person what to fix.
    private func listTools(id: JSONValue) {
        let permission = (try? backend.connect()) ?? backend.permission
        lock.withLock { listedPermission = permission }
        if permission == nil {
            log("plume-cli: Plume is not reachable yet; listing every tool, calls will report why")
        }
        send(result: .object(["tools": .array(MCPToolCatalog.tools(for: permission))]), id: id)
    }

    private func callTool(id: JSONValue, params: JSONValue) {
        guard let name = params["name"]?.stringValue, let tool = AgentTool(rawValue: name) else {
            send(error: -32602, "Unknown tool: \(params["name"]?.stringValue ?? "")", id: id)
            return
        }
        let arguments = params["arguments"] ?? .object([:])
        guard arguments.objectValue != nil else {
            send(error: -32602, "arguments must be an object", id: id)
            return
        }
        let key = Self.key(id)
        let ipcID = lock.withLock { () -> String in
            counter += 1
            let ipcID = "m\(counter)"
            calls[key] = ipcID
            return ipcID
        }

        inFlightGroup.enter()
        work.async { [self] in
            defer { inFlightGroup.leave() }
            let outcome: Result<JSONValue, AgentFailure>
            do {
                outcome = .success(try backend.call(tool, params: arguments, timeout: nil, id: ipcID))
            } catch let failure as AgentFailure {
                outcome = .failure(failure)
            } catch {
                outcome = .failure(AgentFailure(.invalidRequest, String(describing: error)))
            }
            let suppressed = lock.withLock { () -> Bool in
                calls[key] = nil
                return cancelled.remove(key) != nil
            }
            // A cancelled request gets no response, as the protocol requires.
            guard !suppressed else { return }
            send(result: toolResult(outcome), id: id)
        }
    }

    func toolResult(_ outcome: Result<JSONValue, AgentFailure>) -> JSONValue {
        let structured = lock.withLock { protocolVersion >= "2025-06-18" }
        switch outcome {
        case .success(let value):
            var result: [String: JSONValue] = [
                "content": .array([.object(["type": .string("text"), "text": .string(Self.compact(value))])]),
                "isError": .bool(false),
            ]
            if structured { result["structuredContent"] = value }
            return .object(result)
        case .failure(let failure):
            let errorValue = (try? JSONValue.from(failure)) ?? .null
            var result: [String: JSONValue] = [
                "content": .array([.object([
                    "type": .string("text"),
                    "text": .string("\(failure.code.rawValue): \(failure.message)\n\(Self.compact(.object(["error": errorValue])))"),
                ])]),
                "isError": .bool(true),
            ]
            if structured { result["structuredContent"] = .object(["error": errorValue]) }
            return .object(result)
        }
    }

    private func permissionChanged(_ permission: AgentPermission) {
        let notify = lock.withLock { () -> Bool in
            defer { listedPermission = permission }
            return initialized && listedPermission != permission
        }
        if notify {
            send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/tools/list_changed")]))
        }
    }

    // MARK: - Output

    private func send(result: JSONValue, id: JSONValue) {
        send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }

    private func send(error code: Int, _ message: String, id: JSONValue) {
        send(.object([
            "jsonrpc": .string("2.0"), "id": id,
            "error": .object(["code": .number(Double(code)), "message": .string(message)]),
        ]))
    }

    private func send(_ message: JSONValue) {
        write(Self.compact(message))
    }

    static func compact(_ value: JSONValue) -> String {
        guard let data = try? AgentJSON.encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// JSON-RPC ids are strings or numbers; `1` and `"1"` are different ids.
    static func key(_ id: JSONValue) -> String {
        switch id {
        case .string(let value): "s:" + value
        case .number(let value): "n:\(value)"
        default: "x:" + compact(id)
        }
    }
}
