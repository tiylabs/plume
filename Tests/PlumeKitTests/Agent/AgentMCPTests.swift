import Foundation
import PlumeAgent
import PlumeKit

/// The stdio MCP server and the CLI, over a fake connection to Plume.
func runAgentMCPTests() {

    final class FakeBackend: AgentCalling, @unchecked Sendable {
        let lock = NSLock()
        var permission: AgentPermission? = .readWrite
        var onPermissionChanged: (@Sendable (AgentPermission) -> Void)?
        var answer: (AgentTool, JSONValue) throws -> JSONValue = { tool, params in .object(["tool": .string(tool.rawValue), "echo": params]) }
        var cancelledIDs: [String] = []
        var connectFails = false
        var delay: TimeInterval = 0

        func connect() throws -> AgentPermission {
            if connectFails { throw AgentFailure(.authFailed, "no credential") }
            return permission ?? .off
        }

        func call(_ tool: AgentTool, params: JSONValue, timeout: TimeInterval?, id: String?) throws -> JSONValue {
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return try answer(tool, params)
        }

        func cancel(id: String) { lock.withLock { cancelledIDs.append(id) } }
    }

    final class Output: @unchecked Sendable {
        let lock = NSLock()
        var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var messages: [JSONValue] {
            lock.withLock { lines }.map { try! AgentJSON.decoder.decode(JSONValue.self, from: Data($0.utf8)) }
        }
        func response(_ id: Double) -> JSONValue? { messages.first { $0["id"] == .number(id) } }
    }

    func server(_ backend: FakeBackend = FakeBackend()) -> (MCPServer, Output, FakeBackend) {
        let output = Output()
        let server = MCPServer(backend: backend, serverVersion: "9.9", write: { output.append($0) }, log: { _ in })
        return (server, output, backend)
    }

    func initialize(_ s: MCPServer, version: String = "2025-06-18") {
        s.handle(line: #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"\#(version)","capabilities":{},"clientInfo":{"name":"test-client","version":"1"}}}"#)
        s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    }

    Check.suite("Agent MCP · protocol") {

        Check.test("initialize negotiates a supported version and advertises tools only") {
            let (s, out, _) = server()
            initialize(s)
            let result = out.response(0)?["result"]
            Check.equal(result?["protocolVersion"], .string("2025-06-18"))
            Check.equal(result?["capabilities"]?["tools"]?["listChanged"], .bool(true))
            Check.equal(result?["capabilities"]?["resources"], nil)
            Check.equal(result?["serverInfo"]?["name"], .string("plume"))
            Check.equal(s.clientName, "test-client")

            let (old, oldOut, _) = server()
            initialize(old, version: "2024-11-05")
            Check.equal(oldOut.response(0)?["result"]?["protocolVersion"], .string("2024-11-05"))
            let (future, futureOut, _) = server()
            initialize(future, version: "2099-01-01")
            Check.equal(futureOut.response(0)?["result"]?["protocolVersion"], .string(MCPServer.supportedProtocolVersions[0]))
        }

        Check.test("tools/list offers only what the permission allows, with schemas") {
            let backend = FakeBackend()
            backend.permission = .readOnly
            let (s, out, _) = server(backend)
            initialize(s)
            s.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
            guard case .array(let tools)? = out.response(1)?["result"]?["tools"] else { return Check.expect(false, "no tools") }
            Check.equal(tools.compactMap { $0["name"]?.stringValue }, ["get_writing_context", "list_notes", "search_notes", "read_note"])
            Check.equal(tools.first?["inputSchema"]?["type"], .string("object"))

            let full = FakeBackend()
            let (s2, out2, _) = server(full)
            initialize(s2)
            s2.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
            guard case .array(let all)? = out2.response(1)?["result"]?["tools"] else { return Check.expect(false) }
            Check.equal(all.count, 7)
            let modify = all.first { $0["name"] == .string("modify_note") }
            Check.equal(modify?["inputSchema"]?["required"], .array([.string("note_ref"), .string("expected_version"), .string("changes"), .string("request_id")]))
        }

        Check.test("tools/call: results in content and structuredContent; failures are isError tool results") {
            let backend = FakeBackend()
            let (s, out, _) = server(backend)
            initialize(s)
            s.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_notes","arguments":{"limit":5}}}"#)
            s.waitForCalls()
            let ok = out.response(2)?["result"]
            Check.equal(ok?["isError"], .bool(false))
            Check.equal(ok?["structuredContent"]?["echo"]?["limit"], .number(5))
            if case .array(let content)? = ok?["content"] {
                Check.expect(content.first?["text"]?.stringValue?.contains("\"limit\":5") == true)
            }

            backend.answer = { _, _ in throw AgentFailure(.noteBusy, "editing", details: ["reason": "editing"]) }
            s.handle(line: #"{"jsonrpc":"2.0","id":"x","method":"tools/call","params":{"name":"modify_note","arguments":{}}}"#)
            s.waitForCalls()
            let failed = out.messages.first { $0["id"] == .string("x") }?["result"]
            Check.equal(failed?["isError"], .bool(true))
            Check.equal(failed?["structuredContent"]?["error"]?["code"], .string("NOTE_BUSY"))
            if case .array(let content)? = failed?["content"] {
                Check.expect(content.first?["text"]?.stringValue?.hasPrefix("NOTE_BUSY:") == true)
            }
        }

        Check.test("older clients get the text content without structuredContent") {
            let (s, out, _) = server()
            initialize(s, version: "2025-03-26")
            s.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_notes","arguments":{}}}"#)
            s.waitForCalls()
            Check.equal(out.response(2)?["result"]?["structuredContent"], nil)
            Check.expect(out.response(2)?["result"]?["content"] != nil)
        }

        Check.test("protocol errors: parse, batch, unknown method, unknown tool; ping") {
            let (s, out, _) = server()
            initialize(s)
            s.handle(line: "{nope")
            Check.equal(out.messages.last?["error"]?["code"], .number(-32700))
            s.handle(line: "[]")
            Check.equal(out.messages.last?["error"]?["code"], .number(-32600))
            s.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"resources/list"}"#)
            Check.equal(out.response(3)?["error"]?["code"], .number(-32601))
            s.handle(line: #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"delete_note"}}"#)
            Check.equal(out.response(4)?["error"]?["code"], .number(-32602))
            s.handle(line: #"{"jsonrpc":"2.0","id":5,"method":"ping"}"#)
            Check.equal(out.response(5)?["result"], .object([:]))
            s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/unknown"}"#)
            Check.equal(out.messages.count, 6, "a notification gets no answer")
            for message in out.messages { Check.equal(message["jsonrpc"], .string("2.0")) }
        }

        Check.test("a cancelled call is forwarded and gets no response") {
            let backend = FakeBackend()
            backend.delay = 0.3
            let (s, out, _) = server(backend)
            initialize(s)
            s.handle(line: #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"read_note","arguments":{"note_ref":"n"}}}"#)
            Thread.sleep(forTimeInterval: 0.05)
            s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7,"reason":"user"}}"#)
            s.waitForCalls()
            Check.equal(out.response(7), nil)
            Check.equal(backend.cancelledIDs.count, 1)
        }

        Check.test("a permission change after listing sends tools/list_changed") {
            let backend = FakeBackend()
            let (s, out, _) = server(backend)
            initialize(s)
            s.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
            backend.onPermissionChanged?(.readOnly)
            Check.equal(out.messages.last?["method"], .string("notifications/tools/list_changed"))
            let count = out.messages.count
            backend.onPermissionChanged?(.readOnly)
            Check.equal(out.messages.count, count, "no notification when nothing changed")
        }

        Check.test("unreachable Plume still lists tools, so calls can explain why") {
            let backend = FakeBackend()
            backend.connectFails = true
            backend.permission = nil
            let (s, out, _) = server(backend)
            initialize(s)
            s.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
            guard case .array(let tools)? = out.response(1)?["result"]?["tools"] else { return Check.expect(false) }
            Check.equal(tools.count, 7)
        }

        Check.test("run() reads newline-delimited input until EOF and answers in-flight calls") {
            let backend = FakeBackend()
            backend.delay = 0.1
            let (s, out, _) = server(backend)
            let pipe = Pipe()
            let input = """
            {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"list_notes","arguments":{}}}

            """
            pipe.fileHandleForWriting.write(Data(input.utf8))
            try? pipe.fileHandleForWriting.close()
            s.run(input: pipe.fileHandleForReading)
            Check.expect(out.response(1) != nil, "the in-flight call was answered before run() returned")
        }
    }

    Check.suite("Agent CLI") {
        func parse(_ args: [String], input: String = "") -> HelperCommand? {
            try? HelperCommand.parse(args) { _ in Data(input.utf8) }
        }
        func usageError(_ args: [String]) -> Bool {
            do { _ = try HelperCommand.parse(args) { _ in Data() }; return false } catch { return error is HelperCommand.UsageError }
        }

        Check.test("commands map to the same tools and arguments as MCP") {
            Check.equal(parse(["mcp"]), .mcp)
            Check.equal(parse(["notes", "search", "--query", "Agent 接入", "--json"]), .call(.searchNotes, .object(["query": .string("Agent 接入")]), compact: true))
            Check.equal(parse(["notes", "list", "--limit", "5"]), .call(.listNotes, .object(["limit": .number(5)]), compact: false))
            Check.equal(parse(["notes", "read", "--ref", "note:x", "--download"]), .call(.readNote, .object(["note_ref": .string("note:x"), "download": .bool(true)]), compact: false))
            Check.equal(parse(["notes", "create", "--request-id", "u", "--input", "-"], input: "# Hi\n"), .call(.createNote, .object(["markdown": .string("# Hi\n"), "request_id": .string("u")]), compact: false))
            Check.equal(parse(["notes", "modify"], input: #"{"note_ref":"n","expected_version":"v","changes":[],"request_id":"u"}"#),
                        .call(.modifyNote, .object(["note_ref": .string("n"), "expected_version": .string("v"), "changes": .array([]), "request_id": .string("u")]), compact: false))
            Check.equal(parse(["operations", "get", "--request-id", "u"]), .call(.getOperation, .object(["request_id": .string("u")]), compact: false))
            Check.equal(parse(["context", "--example", "a", "--example", "b"]), .call(.getWritingContext, .object(["example_refs": .array([.string("a"), .string("b")])]), compact: false))
        }

        Check.test("usage mistakes are usage errors (exit 2)") {
            for args in [[], ["notes"], ["notes", "search"], ["notes", "create"], ["notes", "list", "--limit", "x"],
                         ["notes", "list", "--bogus"], ["mcp", "extra"], ["frobnicate"], ["notes", "read", "--ref", "a", "--ref", "b"]] {
                Check.expect(usageError(args), "\(args) should be a usage error")
            }
            Check.expect((try? HelperCommand.parse(["notes", "modify"]) { _ in Data("not json".utf8) }) == nil)
        }

        Check.test("run prints the result or {error}, exit 0 or 1") {
            let backend = FakeBackend()
            var printed: [String] = []
            Check.equal(HelperCommand.run(.listNotes, .object([:]), compact: true, backend: backend) { printed.append($0) }, 0)
            Check.expect(printed.last?.contains("\"tool\":\"list_notes\"") == true)
            backend.answer = { _, _ in throw AgentFailure(.authFailed, "no credential") }
            Check.equal(HelperCommand.run(.listNotes, .object([:]), compact: true, backend: backend) { printed.append($0) }, 1)
            Check.expect(printed.last?.contains("\"code\":\"AUTH_FAILED\"") == true, printed.last ?? "")
        }
    }
}
