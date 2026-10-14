import Foundation

/// Answers agent API requests: the seven tools, the permission check, versions, cursors and the
/// operation journal. The app's `AgentAccessCoordinator` wires it to the socket, the vault service
/// and the panel's session; everything here is testable without either.
///
/// On the main actor because the session is, and because "which vault, which epoch, which note is
/// open" are main-actor facts. The vault work itself runs on the vault's queue; the journal's
/// durable writes run on a queue of their own so a `F_FULLFSYNC` never stalls the panel.
@MainActor
public final class NoteAccessHandler {

    /// Who is asking: the authorisation generation and label from the handshake, and whether the
    /// caller has since cancelled (checked before a write is prepared, never after).
    public struct Caller: Sendable {
        public var generation: String
        public var clientLabel: String?
        public var isCancelled: @Sendable () -> Bool

        public init(generation: String, clientLabel: String?, isCancelled: @escaping @Sendable () -> Bool = { false }) {
            self.generation = generation
            self.clientLabel = clientLabel
            self.isCancelled = isCancelled
        }
    }

    let profile: BuildProfile
    let vault: any AgentVaultAccessing
    let journal: OperationJournal
    let access: AgentAccessStore
    let writing: WritingFiles
    let rateLimiter: AgentRateLimiter
    let journalQueue = DispatchQueue(label: "com.tiylabs.plume.cli-journal", qos: .userInitiated)

    /// The open note's session, if a panel exists.
    public weak var session: (any AgentSessionGating)?
    /// Whether the panel holds the keyboard — an AppKit fact the coordinator supplies.
    public var panelHasKeyboard: () -> Bool = { false }
    /// Told after every journal change, so Settings' recent writes can refresh.
    public var onOperationRecorded: ((OperationRecord) -> Void)?
    /// Crash-injection hook for the suite: called with each step name; throwing abandons the
    /// operation at that point, exactly where a killed process would stop.
    public var stepHookForTesting: ((String) throws -> Void)?

    public private(set) var vaultURL: URL
    /// Bumped on every vault change; versions carry it, so none survives a switch.
    public private(set) var epoch = 0
    /// True while Move Notes is moving files: writes answer "try again" instead of racing the move.
    public var writesSuspended = false

    let versions = ExpiringTokenCache<NoteVersionSnapshot>(
        prefix: "version:", lifetime: AgentLimits.versionLifetime, capacity: AgentLimits.versionCacheCapacity
    )
    let cursors = ExpiringTokenCache<NoteCursorState>(
        prefix: "cursor:", lifetime: AgentLimits.cursorLifetime, capacity: AgentLimits.cursorCacheCapacity
    )
    /// Writes in flight, by journal key, so a concurrent retry joins the first instead of racing it.
    var inFlight: [String: Task<Result<WriteResult, AgentFailure>, Never>] = [:]
    /// The vault and input digest each in-flight write was bound to, for a concurrent retry's check.
    var inFlightDigests: [String: (vaultID: String, digest: String)] = [:]
    /// Names reserved by creates that have not finished, so two creates never pick the same one.
    var reservedNames: Set<String> = []
    /// Orders preparation, disk commit and journal settlement together, including different request
    /// IDs. The vault queue alone orders file writes but cannot order the journal around them.
    var writeTail: Task<Void, Never>?
    var writeCount = 0
    public var hasPendingWrites: Bool { writeCount > 0 }

    public func waitForWrites() async {
        while let tail = writeTail, writeCount > 0 { await tail.value }
    }

    func checkEpoch(_ captured: Int) throws {
        guard epoch == captured else {
            throw AgentFailure(.vaultChanged, "the notes folder changed while this request was running; read again")
        }
    }

    public init(
        profile: BuildProfile,
        vaultURL: URL,
        vault: any AgentVaultAccessing,
        journal: OperationJournal,
        access: AgentAccessStore,
        writing: WritingFiles,
        rateLimiter: AgentRateLimiter = AgentRateLimiter()
    ) {
        self.profile = profile
        self.vaultURL = vaultURL
        self.vault = vault
        self.journal = journal
        self.access = access
        self.writing = writing
        self.rateLimiter = rateLimiter
    }

    var vaultID: String { VaultIdentity.of(vaultURL) }

    /// The vault moved or was re-pointed: no version, cursor or reservation from before is valid.
    public func setVault(_ url: URL) {
        guard url.standardizedFileURL != vaultURL.standardizedFileURL else { return }
        vaultURL = url
        epoch += 1
        versions.removeAll()
        cursors.removeAll()
        reservedNames.removeAll()
    }

    // MARK: - Dispatch

    public func handle(method: String, params: JSONValue, caller: Caller) async -> Result<JSONValue, AgentFailure> {
        do {
            guard let tool = AgentTool(rawValue: method) else {
                throw AgentFailure(.invalidRequest, "unknown tool \(method)")
            }
            try authorize(tool, caller: caller)
            switch tool {
            case .getWritingContext:
                return .success(try JSONValue.from(try await writingContext(params.decode(WritingContextRequest.self))))
            case .listNotes:
                return .success(try JSONValue.from(try await listNotes(params.decode(ListNotesRequest.self))))
            case .searchNotes:
                return .success(try JSONValue.from(try await searchNotes(params.decode(SearchNotesRequest.self))))
            case .readNote:
                return .success(try JSONValue.from(try await readNote(params.decode(ReadNoteRequest.self))))
            case .createNote:
                return .success(try JSONValue.from(try await createNote(params.decode(CreateNoteRequest.self), caller: caller)))
            case .modifyNote:
                return .success(try JSONValue.from(try await modifyNote(params.decode(ModifyNoteRequest.self), caller: caller)))
            case .getOperation:
                return .success(try JSONValue.from(try getOperation(params.decode(GetOperationRequest.self), caller: caller)))
            }
        } catch let failure as AgentFailure {
            return .failure(failure.forRequest(params["request_id"]?.stringValue, state: nil))
        } catch {
            return .failure(AgentFailure(.invalidRequest, String(describing: error), requestID: params["request_id"]?.stringValue))
        }
    }

    /// Re-checked on every request, not only at the handshake: a revoke or a permission change takes
    /// effect on the next call over a connection that is already open.
    func authorize(_ tool: AgentTool, caller: Caller) throws {
        let current = access.access
        guard current.permission != .off else {
            throw AgentFailure(.accessDisabled, "agent access is turned off in Plume's settings")
        }
        guard current.generation == caller.generation else {
            throw AgentFailure(.authFailed, "this connection's credential was revoked; copy the new configuration from Plume's settings")
        }
        guard current.permission.allows(tool) else {
            throw AgentFailure(.permissionDenied, "Plume allows this agent to read notes only; the user can allow changes in Settings")
        }
    }

    // MARK: - Notes as the API names them

    func ref(_ filename: String) -> String {
        NoteRef(profile: profile.runtimeKey, vaultID: vaultID, filename: filename).encoded
    }

    func decodeRef(_ raw: String) throws -> NoteRef {
        try NoteRef.decode(raw, profile: profile.runtimeKey, vaultID: vaultID)
    }

    func summary(_ entry: AgentNoteEntry) -> NoteSummary {
        NoteSummary(
            noteRef: ref(entry.filename), filename: entry.filename,
            title: entry.title.isEmpty ? (NoteFilename.title(from: entry.filename) ?? "") : entry.title,
            modified: entry.modified, availability: entry.evicted ? "evicted" : "available"
        )
    }

    /// Stores what was read and returns the version token for it.
    func issueVersion(filename: String, rawHash: String, text: String) -> (String, Date) {
        versions.insert(NoteVersionSnapshot(
            epoch: epoch, vaultID: vaultID, filename: filename, rawHash: rawHash, text: text,
            expiresAt: versions.expiry(after: Date())
        ))
    }

    // MARK: - Reads

    func listNotes(_ request: ListNotesRequest) async throws -> ListNotesResult {
        let limit = try pageSize(request.limit)
        if let cursor = request.cursor {
            let state = try cursorState(cursor, query: nil)
            guard case .notes(let all) = state.items else { throw AgentFailure(.cursorExpired, "this cursor belongs to a search") }
            return page(all, from: state, limit: limit)
        }
        let captured = epoch
        session?.agentSettleNames(Set(session?.agentCurrentFilename.map { [$0] } ?? []))
        let entries = try await vault.agentList(vault: vaultURL)
        try checkEpoch(captured)
        session?.agentSettleNames(Set(entries.map(\.filename)))
        let sorted = entries.sorted {
            $0.modified != $1.modified ? $0.modified > $1.modified : $0.filename < $1.filename
        }.map(summary)
        let state = NoteCursorState(query: nil, vaultID: vaultID, offset: 0, limit: limit, items: .notes(sorted))
        return page(sorted, from: state, limit: limit)
    }

    private func page(_ all: [NoteSummary], from state: NoteCursorState, limit: Int) -> ListNotesResult {
        let slice = Array(all.dropFirst(state.offset).prefix(limit))
        let next = nextCursor(state, total: all.count, taken: slice.count)
        return ListNotesResult(notes: slice, total: all.count, nextCursor: next)
    }

    func searchNotes(_ request: SearchNotesRequest) async throws -> SearchNotesResult {
        let limit = try pageSize(request.limit)
        let query = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw AgentFailure(.invalidRequest, "query is empty") }
        guard query.count <= 500 else { throw AgentFailure(.invalidRequest, "query is longer than 500 characters") }

        let hits: [SearchHit]
        let coverage: SearchCoverage
        var state: NoteCursorState
        if let cursor = request.cursor {
            state = try cursorState(cursor, query: query)
            guard case .hits(let all, let covered) = state.items else {
                throw AgentFailure(.cursorExpired, "this cursor belongs to a listing")
            }
            hits = all
            coverage = covered
        } else {
            var diskOnly: Set<String> = []
            if let current = session?.agentCurrentFilename, session?.agentHasUnsavedChanges(current) == true {
                diskOnly.insert(current)
            }
            let captured = epoch
            session?.agentSettleNames(Set(session?.agentCurrentFilename.map { [$0] } ?? []))
            let outcome = try await vault.agentSearch(query: query, vault: vaultURL, diskOnly: diskOnly)
            try checkEpoch(captured)
            session?.agentSettleNames(Set(outcome.matches.map(\.entry.filename)))
            hits = outcome.matches.map {
                SearchHit(note: summary($0.entry), matchedIn: $0.matchedIn, snippet: $0.snippet, hasConflictMarkers: $0.entry.hasConflictMarkers)
            }
            coverage = SearchCoverage(
                notesTotal: outcome.notesTotal,
                bodiesSearched: outcome.notesTotal - outcome.bodiesNotSearched,
                bodiesNotSearched: outcome.bodiesNotSearched
            )
            state = NoteCursorState(query: query, vaultID: vaultID, offset: 0, limit: limit, items: .hits(hits, coverage))
        }
        let slice = Array(hits.dropFirst(state.offset).prefix(limit))
        return SearchNotesResult(
            query: query, results: slice, total: hits.count,
            nextCursor: nextCursor(state, total: hits.count, taken: slice.count), coverage: coverage
        )
    }

    private func pageSize(_ requested: Int?) throws -> Int {
        let limit = requested ?? AgentLimits.listDefaultPage
        guard (1...AgentLimits.listMaxPage).contains(limit) else {
            throw AgentFailure(.invalidRequest, "limit must be between 1 and \(AgentLimits.listMaxPage)")
        }
        return limit
    }

    private func cursorState(_ token: String, query: String?) throws -> NoteCursorState {
        switch cursors.lookup(token) {
        case .found(let state):
            guard state.vaultID == vaultID else { throw AgentFailure(.vaultChanged, "the notes folder changed; start again") }
            guard state.query == query else {
                throw AgentFailure(.cursorExpired, "this cursor was issued for a different query; start the search again")
            }
            return state
        case .expired, .unknown:
            throw AgentFailure(.cursorExpired, "the cursor expired; start again without one")
        }
    }

    private func nextCursor(_ state: NoteCursorState, total: Int, taken: Int) -> String? {
        let offset = state.offset + taken
        guard offset < total else { return nil }
        var next = state
        next.offset = offset
        return cursors.insert(next).token
    }

    func readNote(_ request: ReadNoteRequest) async throws -> ReadNoteResult {
        let captured = epoch
        let noteRef = try decodeRef(request.noteRef)
        session?.agentSettleNames([noteRef.filename])
        let note = try await vault.agentRead(filename: noteRef.filename, vault: vaultURL, download: request.download ?? false)
        try checkEpoch(captured)
        let (version, expires) = issueVersion(filename: note.filename, rawHash: note.rawHash, text: note.text)
        var warnings: [AgentWarning] = []
        if ConflictMarkers.isPresent(in: note.text) { warnings.append(.conflictMarkers) }
        let unsaved = session?.agentHasUnsavedChanges(note.filename) ?? false
        if unsaved {
            warnings.append(AgentWarning(
                "unsaved_changes",
                "The user is typing in this note; this is the last saved text. A modify will be refused with NOTE_BUSY until their typing is saved."
            ))
        }
        return ReadNoteResult(
            noteRef: noteRef.encoded, filename: note.filename, title: MarkdownDocument.title(of: note.text),
            markdown: LineEndingMap.normalize(note.text), version: version, versionExpiresAt: expires,
            hasUnsavedChanges: unsaved, warnings: warnings
        )
    }

    func writingContext(_ request: WritingContextRequest) async throws -> WritingContextResult {
        let captured = epoch
        session?.agentSettleNames(Set(session?.agentCurrentFilename.map { [$0] } ?? []))
        var warnings: [AgentWarning] = []
        let preferences = writing.preferences(warnings: &warnings)
        let template = try request.templateID.map { try writing.template(id: $0, warnings: &warnings) }

        var target: WritingContextResult.Target?
        if let raw = request.target {
            let noteRef = try decodeRef(raw)
            let note = try await vault.agentRead(filename: noteRef.filename, vault: vaultURL, download: false)
            let text = LineEndingMap.normalize(note.text)
            let excerpt = WritingFiles.excerpt(of: text, limit: 4096)
            target = .init(
                noteRef: noteRef.encoded, title: MarkdownDocument.title(of: text),
                headings: WritingFiles.headings(of: text), excerpt: excerpt.text, truncated: excerpt.truncated
            )
        }

        let refs = request.exampleRefs ?? []
        guard refs.count <= AgentLimits.maxExamples else {
            throw AgentFailure(.invalidRequest, "at most \(AgentLimits.maxExamples) example_refs")
        }
        var examples: [WritingContextResult.Example] = []
        var budget = AgentLimits.examplesMaxBytes
        for raw in refs {
            let noteRef = try decodeRef(raw)
            let note = try await vault.agentRead(filename: noteRef.filename, vault: vaultURL, download: false)
            let text = LineEndingMap.normalize(note.text)
            let cut = WritingFiles.excerpt(of: text, limit: max(0, budget))
            budget -= cut.text.utf8.count
            examples.append(.init(noteRef: noteRef.encoded, title: MarkdownDocument.title(of: text), markdown: cut.text, truncated: cut.truncated))
        }
        if examples.contains(where: \.truncated) {
            warnings.append(AgentWarning(
                "example_truncated",
                "An example was shortened to fit the size limit. Use it for style only; read the note in full before modifying it."
            ))
        }

        try checkEpoch(captured)
        return WritingContextResult(
            format: writing.format(),
            preferences: preferences,
            preferencesVersion: preferences?.version ?? "none",
            template: template,
            templates: writing.templates(),
            target: target,
            examples: examples,
            priority: WritingContextResult.priorityOrder,
            warnings: warnings
        )
    }

    // MARK: - Journal

    func getOperation(_ request: GetOperationRequest, caller: Caller) throws -> OperationStatusResult {
        let requestID = try AgentRequestID.validate(request.requestID)
        guard let record = try journal.checkedRecord(generation: caller.generation, requestID: requestID) else {
            throw AgentFailure(.operationNotFound, "no write with this request_id under the current connection; it was never received")
        }
        guard !record.compacted else {
            throw AgentFailure(.operationExpired, "this write finished more than 7 days ago and its details were discarded; do not run it again")
        }
        return OperationStatusResult(record: record)
    }

    /// Runs a journal write on the journal queue and waits for it to be durable.
    func persist(_ record: OperationRecord) async throws {
        let journal = journal
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            journalQueue.async { continuation.resume(with: Result { try journal.save(record) }) }
        }
        onOperationRecorded?(record)
    }

    func persistSnapshot(_ text: String, of operationID: String, _ which: OperationJournal.Snapshot) async throws {
        let journal = journal
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            journalQueue.async {
                continuation.resume(with: Result { try journal.saveSnapshot(text, of: operationID, which) })
            }
        }
    }
}
