import Foundation

/// The frames that cross the helper ⇄ app socket.
///
/// One connection is a `hello` from the helper, a `welcome` (or an `error` and a close) from the
/// app, then any number of `request` → `response` pairs matched by `id`, in any order. The app may
/// also send an `event` at any time — today only `permission_changed`, which the helper turns into
/// MCP's `notifications/tools/list_changed`. A `cancel` stops the app from starting a request that
/// has not begun; a write already prepared is finished regardless (see the operation journal).
///
/// Decoded strictly: an unknown `type` or method, a missing field, or a major version this build
/// does not speak is an explicit error, never a best guess. The editor bridge's lenient decoding is
/// right for a page this app ships itself and wrong for input from another program.
public struct IPCMessage: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case hello, welcome, request, response, event, cancel, error
    }

    public var type: Kind
    public var id: String?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: AgentFailure?
    public var event: String?
    // hello / welcome
    public var ipcMajor: Int?
    public var profile: String?
    public var instance: String?
    public var appVersion: String?
    public var token: String?
    public var clientLabel: String?
    public var permission: AgentPermission?

    public init(type: Kind) {
        self.type = type
    }

    enum CodingKeys: String, CodingKey {
        case type, id, method, params, result, error, event
        case ipcMajor = "ipc_major"
        case profile, instance
        case appVersion = "app_version"
        case token
        case clientLabel = "client_label"
        case permission
    }

    public static func hello(profile: String, instance: String, appVersion: String, token: String, clientLabel: String?) -> IPCMessage {
        var message = IPCMessage(type: .hello)
        message.ipcMajor = AgentAPI.ipcMajorVersion
        message.profile = profile
        message.instance = instance
        message.appVersion = appVersion
        message.token = token
        message.clientLabel = clientLabel
        return message
    }

    public static func welcome(profile: String, instance: String, appVersion: String, permission: AgentPermission) -> IPCMessage {
        var message = IPCMessage(type: .welcome)
        message.ipcMajor = AgentAPI.ipcMajorVersion
        message.profile = profile
        message.instance = instance
        message.appVersion = appVersion
        message.permission = permission
        return message
    }

    public static func request(id: String, method: AgentTool, params: JSONValue) -> IPCMessage {
        var message = IPCMessage(type: .request)
        message.id = id
        message.method = method.rawValue
        message.params = params
        return message
    }

    public static func response(id: String, result: Result<JSONValue, AgentFailure>) -> IPCMessage {
        var message = IPCMessage(type: .response)
        message.id = id
        switch result {
        case .success(let value): message.result = value
        case .failure(let failure): message.error = failure
        }
        return message
    }

    public static func failure(_ failure: AgentFailure) -> IPCMessage {
        var message = IPCMessage(type: .error)
        message.error = failure
        return message
    }

    public static func permissionChanged(_ permission: AgentPermission) -> IPCMessage {
        var message = IPCMessage(type: .event)
        message.event = "permission_changed"
        message.permission = permission
        return message
    }

    public static func cancel(id: String) -> IPCMessage {
        var message = IPCMessage(type: .cancel)
        message.id = id
        return message
    }

    public static func decode(_ data: Data) throws -> IPCMessage {
        do {
            return try AgentJSON.decoder.decode(IPCMessage.self, from: data)
        } catch {
            throw AgentFailure(.protocolMismatch, "unreadable message: \(AgentJSON.describe(error))")
        }
    }
}
