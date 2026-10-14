import AppKit
import PlumeKit

/// Wires the local agent API into the running app: the socket, the request handler, the access
/// switch, and the panel's session. Owns no view.
///
/// Lifecycle, and why each step is where it is:
///
/// 1. `start()` runs first thing at launch, **before** the vault is resolved. The socket is up and
///    answering handshakes while the vault chooser may still be on screen, so a helper that launched
///    the app hears `VAULT_UNAVAILABLE` at once instead of waiting out its timeout.
/// 2. `attach(…)` runs once the vault service and the panel exist; only then are requests served.
///    Operations a previous run left unfinished are settled here, against the vault they belong to.
/// 3. `vaultChanged(_:)` on every re-point; `suspendWritesForMove()` around Move Notes.
/// 4. `stop()` at quit: no new connections; a write already prepared is in the journal and the next
///    launch settles it.
///
/// Each request runs inside `ProcessInfo.beginActivity(.userInitiated)`. Plume is an accessory app
/// with no visible window most of the time, which is exactly what App Nap throttles — timers and
/// queue hops coalesced into seconds — and an agent waiting on a read is a user waiting.
@MainActor
final class AgentAccessCoordinator {

    let profile = BuildProfile.current
    let access: AgentAccessStore
    let journal: OperationJournal
    let writing: WritingFiles
    private(set) var handler: NoteAccessHandler?
    private var server: AgentSocketServer?
    private var started = false

    /// Why the socket is not being served, for Settings' status row.
    private(set) var serverProblem: String?
    /// Told whenever the journal or the access switch changes, for Settings.
    var onChange: (() -> Void)?

    /// Requests the helper cancelled, by connection and request id.
    private let cancellations = CancellationSet()

    init() {
        let support = BuildProfile.current.fallbackSupportDirectory()
        let agentDirectory = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ))?.appendingPathComponent(BuildProfile.current.supportDirectoryName).appendingPathComponent("Agent")
            ?? support.appendingPathComponent("Agent")
        access = AgentAccessStore(directory: agentDirectory)
        journal = OperationJournal(directory: agentDirectory.appendingPathComponent("Operations"))
        writing = WritingFiles(
            agentDirectory: agentDirectory,
            formatDirectory: Bundle.main.resourceURL?.appendingPathComponent("Agent") ?? agentDirectory
        )
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true

        let bundle = Bundle.main.bundleURL
        let identity = AgentSocketServer.Identity(
            profile: profile,
            instance: AgentInstance.identifier(bundleURL: bundle),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            bundlePath: bundle.path
        )
        let server = AgentSocketServer(runtime: .standard(profile: profile), identity: identity)
        let access = access
        server.authenticate = { token in
            let current = access.access
            guard current.permission != .off else {
                return .failure(AgentFailure(.accessDisabled, "agent access is turned off in Plume's settings"))
            }
            guard AgentAccessStore.matches(token, access.token) else {
                return .failure(AgentFailure(.authFailed, "the credential does not match; copy the configuration from Plume's settings again"))
            }
            return .success(.init(permission: current.permission, generation: current.generation))
        }
        let cancellations = cancellations
        server.onRequest = { [weak self] client, id, method, params, reply in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return reply(.failure(AgentFailure(.appNotReady, "Plume is quitting"))) }
                    self.serve(client: client, id: id, method: method, params: params, reply: reply)
                }
            }
        }
        server.onCancel = { client, id in cancellations.cancel(client.connectionID, id) }

        do {
            try server.start()
            self.server = server
        } catch AgentSocketServer.StartError.ownedElsewhere {
            serverProblem = "another copy of \(profile.displayName) is serving agents"
            NSLog("Plume: agent socket owned by another running copy; this one will not serve agents")
        } catch {
            serverProblem = String(describing: error)
            NSLog("Plume: could not start the agent socket — %@", String(describing: error))
        }
    }

    /// The vault could not be resolved at launch; the chooser is up.
    func vaultUnavailable() {
        server?.readiness = .vaultUnavailable
    }

    func attach(vault: VaultService, vaultURL: URL, session: NoteSession, panelHasKeyboard: @escaping () -> Bool) {
        let handler = NoteAccessHandler(
            profile: profile, vaultURL: vaultURL, vault: vault, journal: journal, access: access, writing: writing
        )
        handler.session = session
        handler.panelHasKeyboard = panelHasKeyboard
        handler.onOperationRecorded = { [weak self] _ in self?.onChange?() }
        self.handler = handler

        // Retention first (it only touches finished records), then the unfinished ones.
        let journal = journal
        DispatchQueue.global(qos: .utility).async { journal.purge() }
        Task { @MainActor in
            await handler.recoverUnfinished()
            self.server?.readiness = .ready
        }
    }

    func vaultChanged(_ url: URL) {
        handler?.setVault(url)
        if server?.readiness == .vaultUnavailable, handler != nil { server?.readiness = .ready }
    }

    /// Move Notes moves files on the main thread. New writes answer "retry" until the move and the
    /// re-point that follows it have both run — the next turn of the run loop, whichever way the move
    /// ended.
    func suspendWritesForMove() {
        handler?.writesSuspended = true
    }

    func resumeWritesAfterMove() { handler?.writesSuspended = false }

    func stop() {
        server?.stop()
        server = nil
    }

    // MARK: - Requests

    private func serve(
        client: AgentSocketServer.Client, id: String, method: String, params: JSONValue,
        reply: @escaping AgentSocketServer.Reply
    ) {
        guard let handler else {
            reply(.failure(AgentFailure(.appNotReady, "Plume is still opening its notes folder")))
            return
        }
        let cancellations = cancellations
        let caller = NoteAccessHandler.Caller(
            generation: client.generation, clientLabel: client.clientLabel,
            isCancelled: { cancellations.isCancelled(client.connectionID, id) }
        )
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Answering an agent request")
        Task { @MainActor in
            let result = await handler.handle(method: method, params: params, caller: caller)
            ProcessInfo.processInfo.endActivity(activity)
            cancellations.forget(client.connectionID, id)
            reply(result)
        }
    }

    // MARK: - Settings

    var permission: AgentPermission { access.access.permission }

    /// Turns access on (or changes its scope), creating the credential and the example writing files
    /// the first time.
    func setPermission(_ permission: AgentPermission) {
        do {
            if permission == .off {
                try access.revoke()
                server?.broadcast(.permissionChanged(.off))
                server?.disconnectAll()
            } else {
                try access.enable(permission)
                writing.installExamplesIfFirstTime { L10n.document($0) }
            }
        } catch {
            NSLog("Plume: could not change agent access — %@", String(describing: error))
        }
        server?.broadcast(IPCMessage.permissionChanged(access.access.permission))
        onChange?()
    }

    /// Destroys the credential and starts a new generation; every configured agent stops working.
    func revoke() {
        try? access.revoke()
        server?.disconnectAll()
        onChange?()
    }

    /// Clears the recent writes and their restore snapshots, and rotates the generation so a cleared
    /// request ID can never be replayed into the empty journal.
    func clearHistory() {
        handler?.writesSuspended = true
        Task { @MainActor in
            await handler?.waitForWrites()
            defer { handler?.writesSuspended = false; onChange?() }
            do {
                try access.rotateGeneration()
                server?.disconnectAll()
                journal.removeAll()
            } catch {
                NSLog("Plume: could not clear agent history — %@", String(describing: error))
            }
        }
    }

    func recentOperations(limit: Int = 50) -> [OperationRecord] {
        Array(journal.all().prefix(limit))
    }

    func restore(_ operationID: String) async -> Result<WriteResult, AgentFailure> {
        guard let handler else { return .failure(AgentFailure(.appNotReady, "not ready")) }
        let result = await handler.restore(operationID: operationID)
        onChange?()
        return result
    }

    /// The helper's path, or why no configuration should be offered for it.
    var helperLocation: Result<URL, AgentInstallLocation.Impermanence> {
        let bundle = Bundle.main.bundleURL
        if let problem = AgentInstallLocation.impermanence(of: bundle) { return .failure(problem) }
        return .success(bundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(AgentAPI.helperExecutableName))
    }

    /// The MCP configuration to paste into an agent: real path, real credential. Shown only on the
    /// person's request and copied to the pasteboard — never logged or written to a file.
    func mcpConfiguration() -> String? {
        guard case .success(let helper) = helperLocation, let token = access.token else { return nil }
        let name = profile == .dev ? "plume-dev" : "plume"
        let config: JSONValue = .object([
            "mcpServers": .object([
                name: .object([
                    "command": .string(helper.path),
                    "args": .array([.string("mcp")]),
                    "env": .object([AgentAPI.tokenEnvironmentKey: .string(token)]),
                ]),
            ]),
        ])
        return (try? AgentJSON.prettyEncoder.encode(config)).map { String(decoding: $0, as: UTF8.self) }
    }

    var isServing: Bool { server?.isRunning == true }
}

/// Cancelled requests, shared with the socket threads.
private final class CancellationSet: @unchecked Sendable {
    private let lock = NSLock()
    private var items: Set<String> = []

    func cancel(_ connection: UUID, _ id: String) { _ = lock.withLock { items.insert("\(connection)/\(id)") } }
    func isCancelled(_ connection: UUID, _ id: String) -> Bool { lock.withLock { items.contains("\(connection)/\(id)") } }
    func forget(_ connection: UUID, _ id: String) { _ = lock.withLock { items.remove("\(connection)/\(id)") } }
}
