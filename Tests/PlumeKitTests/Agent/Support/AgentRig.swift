import Foundation
import PlumeKit

/// Runs async main-actor work to completion from the synchronous suite, by turning the main run loop
/// until it finishes. The real `VaultService` answers through `DispatchQueue.main`, so the loop has
/// to turn for anything to happen.
@MainActor
func runAsync<T>(timeout: TimeInterval = 20, _ body: @escaping @MainActor () async -> T) -> T {
    var result: T?
    Task { @MainActor in result = await body() }
    let deadline = Date().addingTimeInterval(timeout)
    while result == nil, Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    guard let result else { fatalError("async test body did not finish within \(timeout) s") }
    return result
}

/// A temporary vault, a real `VaultService` over it, a journal and an access store in a temporary
/// support folder, and a `NoteAccessHandler` wired to them — the agent API minus the socket.
@MainActor
final class AgentRig {
    let root: URL
    let vaultURL: URL
    let agentDirectory: URL
    let vault: VaultService
    let journal: OperationJournal
    let access: AgentAccessStore
    let writing: WritingFiles
    let gate = VaultWriteGate()
    private(set) var handler: NoteAccessHandler!
    private(set) var caller: NoteAccessHandler.Caller!

    init(permission: AgentPermission = .readWrite, rateLimit: Int = 1000) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-\(UUID().uuidString)")
        vaultURL = root.appendingPathComponent("vault")
        agentDirectory = root.appendingPathComponent("support/Agent")
        try! FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        vault = VaultService(vault: vaultURL, deletedStore: root.appendingPathComponent("deleted"))
        vault.writeGate = gate
        journal = OperationJournal(directory: agentDirectory.appendingPathComponent("Operations"))
        access = AgentAccessStore(directory: agentDirectory)
        writing = WritingFiles(agentDirectory: agentDirectory, formatDirectory: AgentRig.formatDirectory)
        if permission != .off { try! access.enable(permission) }
        makeHandler(rateLimit: rateLimit)
    }

    /// A fresh handler over the same files — what the next launch after a crash sees.
    func makeHandler(rateLimit: Int = 1000) {
        handler = NoteAccessHandler(
            profile: .dev, vaultURL: vaultURL, vault: vault, journal: journal, access: access, writing: writing,
            rateLimiter: AgentRateLimiter(limit: rateLimit)
        )
        caller = NoteAccessHandler.Caller(generation: access.access.generation, clientLabel: "test")
    }

    static var formatDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Resources/Agent")
    }

    // MARK: Files

    @discardableResult
    func seed(_ filename: String, _ text: String) -> URL {
        let url = vaultURL.appendingPathComponent(filename)
        try! Data(text.utf8).write(to: url)
        return url
    }

    func disk(_ filename: String) -> String? {
        (try? Data(contentsOf: vaultURL.appendingPathComponent(filename))).map { String(decoding: $0, as: UTF8.self) }
    }

    var noteFiles: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: vaultURL.path)) ?? []).filter(NoteFilename.isNoteFile).sorted()
    }

    // MARK: Calls

    func call(_ tool: AgentTool, _ params: [String: JSONValue], caller: NoteAccessHandler.Caller? = nil) -> Result<JSONValue, AgentFailure> {
        let handler = handler!
        let who = caller ?? self.caller!
        return runAsync { await handler.handle(method: tool.rawValue, params: .object(params), caller: who) }
    }

    func ok<T: Decodable>(_ tool: AgentTool, _ params: [String: JSONValue], as type: T.Type, file: StaticString = #fileID, line: UInt = #line) -> T? {
        switch call(tool, params) {
        case .success(let value):
            return try? value.decode(type)
        case .failure(let failure):
            Check.expect(false, "\(tool.rawValue) failed: \(failure.code.rawValue) \(failure.message)", file: file, line: line)
            return nil
        }
    }

    func failure(_ tool: AgentTool, _ params: [String: JSONValue], caller: NoteAccessHandler.Caller? = nil) -> AgentFailure? {
        if case .failure(let failure) = call(tool, params, caller: caller) { return failure }
        return nil
    }

    func refOf(_ filename: String) -> String {
        NoteRef(profile: "dev", vaultID: VaultIdentity.of(vaultURL), filename: filename).encoded
    }

    func read(_ filename: String) -> ReadNoteResult? {
        ok(.readNote, ["note_ref": .string(refOf(filename))], as: ReadNoteResult.self)
    }

    func create(_ markdown: String, id: String = UUID().uuidString) -> Result<JSONValue, AgentFailure> {
        call(.createNote, ["markdown": .string(markdown), "request_id": .string(id)])
    }

    func modify(_ filename: String, version: String, _ changes: [NoteChange], id: String = UUID().uuidString) -> Result<JSONValue, AgentFailure> {
        let encoded = try! JSONValue.from(changes)
        return call(.modifyNote, [
            "note_ref": .string(refOf(filename)), "expected_version": .string(version),
            "changes": encoded, "request_id": .string(id),
        ])
    }
}

func uuid() -> String { UUID().uuidString }

extension Result where Failure == AgentFailure {
    var failureCode: AgentErrorCode? {
        if case .failure(let failure) = self { return failure.code }
        return nil
    }

    func value<T: Decodable>(_ type: T.Type) -> T? where Success == JSONValue {
        if case .success(let value) = self { return try? value.decode(type) }
        return nil
    }
}
