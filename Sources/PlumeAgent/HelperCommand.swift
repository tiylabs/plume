import Foundation
import PlumeKit

/// The helper's command line: `mcp`, and the CLI that does the same work for agents with a shell.
///
///     plume-cli mcp
///     plume-cli context [--target REF] [--template ID] [--example REF]…
///     plume-cli notes list [--cursor C] [--limit N]
///     plume-cli notes search --query Q [--cursor C] [--limit N]
///     plume-cli notes read --ref REF [--download]
///     plume-cli notes create [--input FILE] --request-id UUID
///     plume-cli notes modify [--input FILE]
///     plume-cli operations get --request-id UUID
///
/// Output is the same JSON the MCP tools return — pretty by default, compact with `--json` — on
/// stdout; diagnostics go to stderr. Exit 0 on success, 1 on a failure from Plume (the JSON is then
/// `{"error": {...}}`), 2 on a usage mistake. Note text comes from a file or stdin, never from argv:
/// long text, newlines and quoting do not survive a shell command line well, and argv is visible to
/// every process on the machine.
public enum HelperCommand: Equatable {
    case mcp
    case call(AgentTool, JSONValue, compact: Bool)
    case help
    case version

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public var description: String
        init(_ description: String) { self.description = description }
    }

    public static let usage = """
    usage: plume-cli mcp
           plume-cli context [--target REF] [--template ID] [--example REF]... [--json]
           plume-cli notes list [--cursor CURSOR] [--limit N] [--json]
           plume-cli notes search --query TEXT [--cursor CURSOR] [--limit N] [--json]
           plume-cli notes read --ref REF [--download] [--json]
           plume-cli notes create [--input FILE|-] --request-id UUID [--json]
           plume-cli notes modify [--input FILE|-] [--json]
           plume-cli operations get --request-id UUID [--json]

    The credential is read from \(AgentAPI.tokenEnvironmentKey). Note text and modify requests are read
    from --input or, when it is omitted or '-', from stdin.
    """

    /// Parses argv (without the program name). `readInput` reads `--input`'s file, or stdin for nil.
    public static func parse(_ arguments: [String], readInput: (String?) throws -> Data) throws -> HelperCommand {
        var args = arguments
        guard let first = args.first else { throw UsageError("missing command") }
        args.removeFirst()

        switch first {
        case "mcp":
            guard args.isEmpty else { throw UsageError("mcp takes no arguments") }
            return .mcp
        case "-h", "--help", "help":
            return .help
        case "--version", "version":
            return .version
        default:
            break
        }

        var options = try Options(args)
        let compact = options.flag("--json")
        let command: (AgentTool, JSONValue)

        switch first {
        case "context":
            var params: [String: JSONValue] = [:]
            if let target = try options.value("--target") { params["target"] = .string(target) }
            if let template = try options.value("--template") { params["template_id"] = .string(template) }
            let examples = try options.values("--example")
            if !examples.isEmpty { params["example_refs"] = .array(examples.map(JSONValue.string)) }
            command = (.getWritingContext, .object(params))
        case "notes":
            guard let sub = options.positional() else { throw UsageError("notes needs list, search, read, create or modify") }
            switch sub {
            case "list":
                command = (.listNotes, .object(try paging(&options)))
            case "search":
                guard let query = try options.value("--query") else { throw UsageError("notes search needs --query") }
                var params = try paging(&options)
                params["query"] = .string(query)
                command = (.searchNotes, .object(params))
            case "read":
                guard let ref = try options.value("--ref") else { throw UsageError("notes read needs --ref") }
                var params: [String: JSONValue] = ["note_ref": .string(ref)]
                if options.flag("--download") { params["download"] = .bool(true) }
                command = (.readNote, .object(params))
            case "create":
                guard let requestID = try options.value("--request-id") else {
                    throw UsageError("notes create needs --request-id (a new UUID, for example from uuidgen)")
                }
                let data = try readInput(input(try options.value("--input")))
                guard let markdown = String(data: data, encoding: .utf8) else { throw UsageError("the input is not UTF-8 text") }
                command = (.createNote, .object(["markdown": .string(markdown), "request_id": .string(requestID)]))
            case "modify":
                let data = try readInput(input(try options.value("--input")))
                guard let value = try? AgentJSON.decoder.decode(JSONValue.self, from: data), value.objectValue != nil else {
                    throw UsageError("the modify input must be a JSON object with note_ref, expected_version, changes and request_id")
                }
                command = (.modifyNote, value)
            default:
                throw UsageError("unknown notes command \(sub)")
            }
        case "operations":
            guard options.positional() == "get" else { throw UsageError("operations needs get") }
            guard let requestID = try options.value("--request-id") else { throw UsageError("operations get needs --request-id") }
            command = (.getOperation, .object(["request_id": .string(requestID)]))
        default:
            throw UsageError("unknown command \(first)")
        }

        try options.finish()
        return .call(command.0, command.1, compact: compact)
    }

    private static func input(_ path: String?) -> String? {
        path == "-" ? nil : path
    }

    private static func paging(_ options: inout Options) throws -> [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        if let cursor = try options.value("--cursor") { params["cursor"] = .string(cursor) }
        if let raw = try options.value("--limit") {
            guard let limit = Int(raw) else { throw UsageError("--limit must be a number") }
            params["limit"] = .number(Double(limit))
        }
        return params
    }

    /// Runs a parsed CLI call: prints the JSON result (or `{"error": …}`) and returns the exit code.
    public static func run(
        _ tool: AgentTool, _ params: JSONValue, compact: Bool, backend: any AgentCalling,
        output: (String) -> Void
    ) -> Int32 {
        let encoder = compact ? AgentJSON.encoder : AgentJSON.prettyEncoder
        func print(_ value: some Encodable) {
            output((try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null")
        }
        do {
            print(try backend.call(tool, params: params, timeout: nil, id: nil, isCancelled: { false }))
            return 0
        } catch let failure as AgentFailure {
            print(["error": failure])
            return 1
        } catch {
            print(["error": AgentFailure(.invalidRequest, String(describing: error))])
            return 1
        }
    }
}

/// `--name value` options, each allowed once unless read with `values`, plus positionals.
private struct Options {
    private var items: [String]

    init(_ items: [String]) throws {
        self.items = items
    }

    mutating func flag(_ name: String) -> Bool {
        guard let index = items.firstIndex(of: name) else { return false }
        items.remove(at: index)
        return true
    }

    mutating func value(_ name: String) throws -> String? {
        let all = try values(name)
        guard all.count <= 1 else { throw HelperCommand.UsageError("\(name) given more than once") }
        return all.first
    }

    mutating func values(_ name: String) throws -> [String] {
        var found: [String] = []
        while let index = items.firstIndex(of: name) {
            guard index + 1 < items.count else { throw HelperCommand.UsageError("\(name) needs a value") }
            found.append(items[index + 1])
            items.removeSubrange(index...(index + 1))
        }
        return found
    }

    mutating func positional() -> String? {
        guard let index = items.firstIndex(where: { !$0.hasPrefix("--") }) else { return nil }
        return items.remove(at: index)
    }

    func finish() throws {
        if let extra = items.first { throw HelperCommand.UsageError("unexpected argument \(extra)") }
    }
}
