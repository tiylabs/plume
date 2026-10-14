import Foundation

/// `create_note`, `modify_note`, restore, and recovery after a crash.
///
/// Every write follows the same order, and the order is the design:
///
///     accepted  (journal)            the request is known; nothing has changed
///     prepared  (journal, durable)   target, reserved name, before and after text are on disk
///     written   (vault)              the note file is replaced or created
///     saved     (journal, durable)   only now is success reported
///
/// A crash between any two lines leaves the journal one step behind the vault at most, and
/// `recover` can tell which side of the write it stopped on by comparing the note's hash with the
/// before and after hashes in the record.
extension NoteAccessHandler {

    /// What a create's request ID is bound to. The text is normalised the way it will be saved, so a
    /// retry that differs only by a trailing newline is the same request.
    private struct CreateInput: Encodable {
        var kind = "create"
        var markdown: String
    }

    private struct ModifyInput: Encodable {
        var kind = "modify"
        var noteRef: String
        var expectedVersion: String
        var changes: [NoteChange]

        enum CodingKeys: String, CodingKey {
            case kind
            case noteRef = "note_ref"
            case expectedVersion = "expected_version"
            case changes
        }
    }

    // MARK: - Create

    func createNote(_ request: CreateNoteRequest, caller: Caller) async throws -> WriteResult {
        let text = MarkdownDocument.normalizeTrailingNewline(request.markdown)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentFailure(.emptyContent, "markdown is empty")
        }
        guard text.utf8.count <= AgentLimits.noteMaxBytes else {
            throw AgentFailure(.contentTooLarge, "a note may be at most \(AgentLimits.noteMaxBytes) bytes")
        }

        return try await idempotent(request.requestID, caller: caller, digest: {
            OperationDigest.of(CreateInput(markdown: text), vaultID: $0)
        }) { digest, requestID in
            try self.admitNewWrite(caller)
            var record = OperationRecord(
                requestID: requestID, generation: caller.generation, kind: .create, inputDigest: digest,
                vaultPath: self.vaultURL.path, vaultID: self.vaultID, clientLabel: caller.clientLabel
            )
            record.title = MarkdownDocument.title(of: text)
            try await self.persist(record)
            try self.step("accepted")

            let name: String
            do {
                name = try await self.vault.agentReserveName(text: text, vault: URL(fileURLWithPath: record.vaultPath), excluding: self.reservedNames)
            } catch {
                try await self.reject(&record, error)
            }
            self.reservedNames.insert(name)
            defer { self.reservedNames.remove(name) }

            record.filename = name
            record.noteRef = NoteRef(profile: self.profile.runtimeKey, vaultID: record.vaultID, filename: name).encoded
            record.afterHash = ContentHash.of(text)
            try await self.persistSnapshot(text, of: record.operationID, .after)
            try self.authorize(.createNote, caller: caller)
            guard !caller.isCancelled() else { try await self.reject(&record, AgentFailure(.requestTimeout, "cancelled before preparation")) }
            record.state = .prepared
            try await self.persist(record)
            try self.step("prepared")

            let hash: String
            do {
                hash = try await self.vault.agentCreate(filename: name, vault: URL(fileURLWithPath: record.vaultPath), text: text)
            } catch {
                try await self.reject(&record, error)
            }
            try self.step("written")
            return try await self.finishSaved(&record, hash: hash, text: text, changed: true, warnings: FormatWarnings.check(text))
        }
    }

    // MARK: - Modify

    func modifyNote(_ request: ModifyNoteRequest, caller: Caller) async throws -> WriteResult {
        let input = ModifyInput(noteRef: request.noteRef, expectedVersion: request.expectedVersion, changes: request.changes)

        return try await idempotent(request.requestID, caller: caller, digest: {
            OperationDigest.of(input, vaultID: $0)
        }) { digest, requestID in
            let noteRef = try self.decodeRef(request.noteRef)
            let snapshot = try self.snapshot(for: request.expectedVersion, filename: noteRef.filename)
            let candidate = try NoteChangePlanner.apply(request.changes, to: snapshot.text)
            try self.admitNewWrite(caller)

            var record = OperationRecord(
                requestID: requestID, generation: caller.generation, kind: .modify, inputDigest: digest,
                vaultPath: self.vaultURL.path, vaultID: self.vaultID, filename: noteRef.filename,
                clientLabel: caller.clientLabel
            )
            record.noteRef = noteRef.encoded
            record.title = MarkdownDocument.title(of: candidate)
            record.beforeHash = snapshot.rawHash
            try await self.persist(record)
            try self.step("accepted")

            if candidate == snapshot.text {
                // Nothing to write — but only if the note is still what was read; otherwise the
                // agent's picture of it is stale, and "no change" would be a claim about text it
                // has not seen.
                let current: String?
                do {
                    current = try await self.vault.agentHash(filename: noteRef.filename, vault: self.vaultURL)
                } catch {
                    try await self.reject(&record, error)
                }
                guard current == snapshot.rawHash else {
                    try await self.reject(&record, AgentFailure(.versionConflict, "the note changed since it was read; read it again"))
                }
                record.afterHash = snapshot.rawHash
                return try await self.finishSaved(&record, hash: snapshot.rawHash, text: snapshot.text, changed: false, warnings: [])
            }

            return try await self.commitReplace(
                &record, before: snapshot.text, expectedHash: snapshot.rawHash, after: candidate,
                warnings: FormatWarnings.check(candidate), caller: caller
            )
        }
    }

    private func snapshot(for token: String, filename: String) throws -> NoteVersionSnapshot {
        switch versions.lookup(token) {
        case .found(let snapshot):
            guard snapshot.vaultID == vaultID, snapshot.epoch == epoch else {
                throw AgentFailure(.vaultChanged, "the notes folder changed since this version was read; search and read again")
            }
            guard snapshot.filename == filename else {
                throw AgentFailure(.invalidRequest, "expected_version was read from a different note")
            }
            return snapshot
        case .expired:
            throw AgentFailure(.versionExpired, "this version expired (versions last 10 minutes and do not survive a restart); read the note again")
        case .unknown:
            throw AgentFailure(.invalidRequest, "expected_version is not a version returned by read_note")
        }
    }

    /// The prepared → written → saved half of a modify or restore, with the session's gate.
    func commitReplace(
        _ record: inout OperationRecord, before: String, expectedHash: String, after: String, warnings: [AgentWarning],
        caller: Caller? = nil
    ) async throws -> WriteResult {
        guard let filename = record.filename else { throw AgentFailure(.saveFailed, "no target") }

        var ticket: AgentWriteTicket?
        switch session?.agentBeginWrite(filename, panelHasKeyboard: panelHasKeyboard()) {
        case .failure(let busy)?: try await reject(&record, busy)
        case .success(let claimed)?: ticket = claimed
        case nil: break
        }

        record.afterHash = ContentHash.of(after)
        do {
            try await persistSnapshot(before, of: record.operationID, .before)
            try await persistSnapshot(after, of: record.operationID, .after)
            if let caller {
                try authorize(.modifyNote, caller: caller)
                guard !caller.isCancelled() else { throw AgentFailure(.requestTimeout, "cancelled before preparation") }
            }
            record.state = .prepared
            try await persist(record)
        } catch {
            if let ticket { session?.agentAbortWrite(ticket) }
            throw AgentFailure(.saveFailed, "could not record the change before making it: \(error)")
                .forRequest(record.requestID, state: .accepted)
        }
        do { try step("prepared") } catch {
            if let ticket { session?.agentAbortWrite(ticket) }
            throw error
        }

        let hash: String
        do {
            hash = try await vault.agentReplace(filename: filename, vault: URL(fileURLWithPath: record.vaultPath), expectedHash: expectedHash, text: after)
        } catch {
            if let ticket { session?.agentAbortWrite(ticket) }
            try await reject(&record, error)
        }
        var warnings = warnings
        if let ticket {
            warnings += session?.agentFinishWrite(ticket, savedText: after, savedHash: hash) ?? []
        }
        try step("written")
        return try await finishSaved(&record, hash: hash, text: after, changed: true, warnings: warnings)
    }

    // MARK: - Restore (Settings)

    /// Puts back the text an earlier modify replaced. Only while the note is still exactly what that
    /// modify left — otherwise restoring would discard whatever came after, and the person is told to
    /// copy the old text out by hand instead.
    public func restore(operationID: String) async -> Result<WriteResult, AgentFailure> {
        let previous = writeTail
        writeCount += 1
        let task = Task { @MainActor in
            defer { self.writeCount -= 1 }
            await previous?.value
            return await self.performRestore(operationID: operationID)
        }
        writeTail = Task { _ = await task.value }
        return await task.value
    }

    private func performRestore(operationID: String) async -> Result<WriteResult, AgentFailure> {
        do {
            guard let original = journal.operation(id: operationID), original.kind != .create,
                  original.state == .saved, original.changed == true, !original.compacted,
                  let filename = original.filename, let afterHash = original.afterHash,
                  let beforeText = journal.snapshot(of: operationID, .before)
            else { throw AgentFailure(.invalidRequest, "this change cannot be restored") }
            guard original.vaultID == vaultID else {
                throw AgentFailure(.vaultChanged, "this change was made in another notes folder")
            }
            let current = try await vault.agentHash(filename: filename, vault: vaultURL)
            guard current == afterHash else {
                throw AgentFailure(.versionConflict, "the note has changed since; restoring would discard the newer text")
            }

            var record = OperationRecord(
                requestID: UUID().uuidString.lowercased(), generation: access.access.generation, kind: .restore,
                inputDigest: "restore:" + operationID, vaultPath: vaultURL.path, vaultID: vaultID,
                filename: filename, clientLabel: "Plume"
            )
            record.restoreOf = operationID
            record.noteRef = ref(filename)
            record.title = MarkdownDocument.title(of: beforeText)
            record.beforeHash = afterHash
            try await persist(record)
            let afterText = journal.snapshot(of: operationID, .after) ?? ""
            return .success(try await commitReplace(
                &record, before: afterText, expectedHash: afterHash, after: beforeText, warnings: []
            ))
        } catch let failure as AgentFailure {
            return .failure(failure)
        } catch {
            return .failure(AgentFailure(.saveFailed, String(describing: error)))
        }
    }

    // MARK: - Idempotency

    /// Runs a write once per (generation, request ID).
    ///
    /// The journal is consulted before anything about the current vault or the version is checked,
    /// so a retry after a vault switch, or after the version expired, still finds and returns the
    /// original operation. Same ID, same input: the original's result. Same ID, different input:
    /// `REQUEST_ID_REUSED`. Same ID while the first is still running: wait for it.
    private func idempotent(
        _ rawRequestID: String,
        caller: Caller,
        digest: @escaping (String) -> String,
        _ start: @escaping @MainActor (String, String) async throws -> WriteResult
    ) async throws -> WriteResult {
        let requestID = try AgentRequestID.validate(rawRequestID)
        let key = OperationJournal.key(generation: caller.generation, requestID: requestID)

        if let task = inFlight[key], let bound = inFlightDigests[key] {
            guard digest(bound.vaultID) == bound.digest else { throw reused(requestID) }
            return try await task.value.get()
        }
        let existing = try journal.checkedRecord(generation: caller.generation, requestID: requestID)
        if let existing, digest(existing.vaultID) != existing.inputDigest { throw reused(requestID) }

        let vaultID = existing?.vaultID ?? vaultID
        let capturedEpoch = epoch
        let inputDigest = digest(vaultID)
        let previous = writeTail
        writeCount += 1
        let task = Task { @MainActor () -> Result<WriteResult, AgentFailure> in
            defer { self.writeCount -= 1 }
            await previous?.value
            do {
                if let existing { return .success(try await self.replay(existing)) }
                try self.checkEpoch(capturedEpoch)
                try self.authorize(.modifyNote, caller: caller)
                await self.recoverUnfinished()
                guard self.journal.unfinished().allSatisfy({ $0.vaultID != vaultID }) else {
                    throw AgentFailure(.noteBusy, "a previous write is still awaiting recovery", details: ["reason": "saving"])
                }
                return .success(try await start(inputDigest, requestID))
            } catch let failure as AgentFailure {
                return .failure(failure.forRequest(requestID, state: failure.operationState))
            } catch {
                return .failure(AgentFailure(.saveFailed, String(describing: error)).forRequest(requestID, state: nil))
            }
        }
        writeTail = Task { _ = await task.value }
        inFlight[key] = task
        inFlightDigests[key] = (vaultID, inputDigest)
        defer {
            inFlight[key] = nil
            inFlightDigests[key] = nil
        }
        return try await task.value.get()
    }

    private func reused(_ requestID: String) -> AgentFailure {
        AgentFailure(
            .requestIDReused, "this request_id was already used for a different request; generate a new UUID",
            requestID: requestID
        )
    }

    /// The answer for a request the journal already has.
    private func replay(_ record: OperationRecord) async throws -> WriteResult {
        var record = record
        if !record.state.isTerminal { record = await recover(record) }
        switch record.state {
        case .saved:
            var warnings = record.warnings
            warnings.append(AgentWarning("replayed", "This request was already completed; nothing was written again. Read the note again before another change."))
            return WriteResult(
                operationID: record.operationID, requestID: record.requestID, state: .saved,
                noteRef: record.noteRef ?? "", filename: record.filename ?? "", title: record.title ?? "",
                version: nil, versionExpiresAt: nil, changed: record.changed ?? false, warnings: warnings
            )
        case .rejected:
            throw (record.error ?? AgentFailure(.saveFailed, "the write was not made")).forRequest(record.requestID, state: .rejected)
        case .outcomeUnknown:
            throw unknownOutcome(record)
        case .accepted, .prepared:
            throw AgentFailure(.noteBusy, "this write is waiting to be finished; ask again in a moment", details: ["reason": "saving"])
                .forRequest(record.requestID, state: record.state)
        }
    }

    // MARK: - Steps

    func admitNewWrite(_ caller: Caller) throws {
        guard !writesSuspended else {
            throw AgentFailure(.appNotReady, "Plume is moving the notes folder; retry in a moment", retryable: true)
        }
        guard !caller.isCancelled() else {
            throw AgentFailure(.requestTimeout, "the request was cancelled before anything was written", retryable: false)
        }
        try authorize(.modifyNote, caller: caller)
        try rateLimiter.take()
    }

    func step(_ name: String) throws {
        try stepHookForTesting?(name)
    }

    /// Marks the operation rejected — the note is unchanged — and throws the reason.
    func reject(_ record: inout OperationRecord, _ error: any Error) async throws -> Never {
        let failure = (error as? AgentFailure) ?? AgentFailure(.saveFailed, String(describing: error))
        record.state = .rejected
        record.error = failure
        try? await persist(record)
        throw failure.forRequest(record.requestID, state: .rejected)
    }

    func finishSaved(
        _ record: inout OperationRecord, hash: String, text: String, changed: Bool, warnings: [AgentWarning]
    ) async throws -> WriteResult {
        record.state = .saved
        record.afterHash = hash
        record.changed = changed
        record.warnings = warnings
        record.updatedAt = Date()
        do {
            try await persist(record)
        } catch {
            // The note is written but the success is not recorded. Not a plain success: the caller
            // is told to ask, and the next launch (or the next retry) reconciles the record.
            throw AgentFailure(
                .saveFailed, "the note was saved, but Plume could not record it; ask get_operation with this request_id",
                retryable: true
            ).forRequest(record.requestID, state: .prepared)
        }
        var version: String?
        var expires: Date?
        if let filename = record.filename, record.vaultID == vaultID {
            (version, expires) = issueVersion(filename: filename, rawHash: hash, text: text)
        }
        return WriteResult(
            operationID: record.operationID, requestID: record.requestID, state: .saved,
            noteRef: record.noteRef ?? "", filename: record.filename ?? "", title: record.title ?? "",
            version: version, versionExpiresAt: expires, changed: changed, warnings: warnings
        )
    }

    func unknownOutcome(_ record: OperationRecord) -> AgentFailure {
        AgentFailure(
            .outcomeUnknown,
            "Plume stopped in the middle of this write and cannot prove whether it was applied; read the note to see its current state",
            details: record.filename.map { ["filename": $0] }
        ).forRequest(record.requestID, state: .outcomeUnknown)
    }

    // MARK: - Recovery

    /// Settles every operation a previous run left unfinished. Run once the vault is ready.
    public func recoverUnfinished() async {
        for record in journal.unfinished() { _ = await recover(record) }
    }

    /// One unfinished operation, against what is on disk now:
    ///
    /// | on disk | then |
    /// |---|---|
    /// | still the before text | finish the write with the recorded after text — never regenerated |
    /// | already the after text | record it as saved — never applied twice |
    /// | a create's reserved name is free | create it there — never under a second name |
    /// | anything else | `outcome_unknown`: keep the snapshots, overwrite nothing, create nothing |
    @discardableResult
    func recover(_ record: OperationRecord) async -> OperationRecord {
        var record = record
        switch record.state {
        case .accepted:
            record.state = .rejected
            record.error = AgentFailure(.saveFailed, "Plume stopped before this write was prepared; nothing was changed")
            try? await persist(record)
            return record
        case .prepared:
            break
        default:
            return record
        }

        guard record.vaultID == vaultID, let filename = record.filename,
              (try? NotePathPolicy.validate(filename)) != nil,
              let after = journal.snapshot(of: record.operationID, .after),
              ContentHash.of(after) == record.afterHash
        else { return await markUnknown(record) }
        let boundVault = URL(fileURLWithPath: record.vaultPath)
        guard VaultIdentity.of(boundVault) == record.vaultID else { return await markUnknown(record) }

        let onDisk: String?
        do {
            onDisk = try await vault.agentHash(filename: filename, vault: boundVault)
        } catch {
            return await markUnknown(record)
        }

        if onDisk != nil, onDisk == record.afterHash {
            return await markRecoveredSaved(record, hash: onDisk!)
        }
        switch record.kind {
        case .create where onDisk == nil:
            guard let hash = try? await vault.agentCreate(filename: filename, vault: boundVault, text: after) else {
                return await markUnknown(record)
            }
            return await markRecoveredSaved(record, hash: hash)
        case .modify where onDisk == record.beforeHash, .restore where onDisk == record.beforeHash:
            guard let expected = record.beforeHash else { return await markUnknown(record) }
            switch session?.agentBeginWrite(filename, panelHasKeyboard: panelHasKeyboard()) {
            case .failure?:
                return record  // the person is editing it; leave it prepared for a later pass
            case .success(let ticket)?:
                do {
                    let hash = try await vault.agentReplace(filename: filename, vault: boundVault, expectedHash: expected, text: after)
                    _ = session?.agentFinishWrite(ticket, savedText: after, savedHash: hash)
                    return await markRecoveredSaved(record, hash: hash)
                } catch {
                    session?.agentAbortWrite(ticket)
                    return await markUnknown(record)
                }
            case nil:
                guard let hash = try? await vault.agentReplace(filename: filename, vault: boundVault, expectedHash: expected, text: after) else {
                    return await markUnknown(record)
                }
                return await markRecoveredSaved(record, hash: hash)
            }
        default:
            return await markUnknown(record)
        }
    }

    private func markRecoveredSaved(_ record: OperationRecord, hash: String) async -> OperationRecord {
        var record = record
        record.state = .saved
        record.afterHash = hash
        record.changed = record.changed ?? (record.beforeHash != hash)
        try? await persist(record)
        return record
    }

    private func markUnknown(_ record: OperationRecord) async -> OperationRecord {
        var record = record
        record.state = .outcomeUnknown
        record.error = unknownOutcome(record)
        try? await persist(record)
        return record
    }
}
