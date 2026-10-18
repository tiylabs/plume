import Foundation

/// Any JSON value, decoded without a schema.
///
/// The IPC envelope and JSON-RPC both carry a `params` or `result` whose type depends on a method
/// name read from the same object. Swift's `Codable` wants the type before it decodes, so the
/// envelope keeps the payload as this and the dispatcher decodes it again, strictly, once it knows
/// which request it is holding. Strictness lives in that second decode; this type accepts anything.
public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Integers stay integers on the wire: JSON-RPC ids and limits are compared by agents
            // that may not treat `3.0` and `3` as the same thing.
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Any `Encodable`, as a value, through the API's own encoder so key names match the wire.
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        try AgentJSON.decoder.decode(JSONValue.self, from: AgentJSON.encoder.encode(value))
    }

    /// This value as a typed request. Throws `INVALID_REQUEST` with the decoder's own explanation,
    /// because "expected String at changes[2].old_text" is what an agent needs to fix its call.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        do {
            let data = try AgentJSON.encoder.encode(self)
            return try AgentJSON.decoder.decode(type, from: data)
        } catch let failure as AgentFailure {
            throw failure
        } catch {
            throw AgentFailure(.invalidRequest, AgentJSON.describe(error))
        }
    }
}

/// The one encoder and decoder of the agent API, so every surface writes the same bytes.
public enum AgentJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var prettyEncoder: JSONEncoder {
        let encoder = Self.encoder
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A decoding error, as one line a caller can act on.
    public static func describe(_ error: any Error) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { key in
                key.intValue.map { "[\($0)]" } ?? key.stringValue
            }
            return keys.isEmpty ? "the request" : keys.joined(separator: ".").replacingOccurrences(of: ".[", with: "[")
        }
        switch error {
        case DecodingError.keyNotFound(let key, let context):
            let parent = path(context)
            return "missing field \(key.stringValue)" + (parent == "the request" ? "" : " in \(parent)")
        case DecodingError.typeMismatch(let type, let context):
            return "wrong type at \(path(context)): expected \(type)"
        case DecodingError.valueNotFound(let type, let context):
            return "missing value at \(path(context)): expected \(type)"
        case DecodingError.dataCorrupted(let context):
            return "invalid value at \(path(context)): \(context.debugDescription)"
        default:
            return String(describing: error)
        }
    }
}
