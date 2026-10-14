import Darwin
import Foundation

/// The agent API's reads and writes, on the vault's serial queue.
///
/// Same queue, same index, same iCloud rules as the panel: a download waits on `downloads`, never in
/// front of a save, and an evicted note is never read on the way to answering a search.
extension VaultService: AgentVaultAccessing {

    /// Runs `body` on the vault queue if the queue is still pointed at `vault`.
    private func onQueue<T: Sendable>(
        vault: URL, _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard Self.sameFolder(self.vaultURL, vault) else {
                    continuation.resume(throwing: AgentFailure(
                        .vaultChanged, "the notes folder changed while the request was waiting; list or search again"
                    ))
                    return
                }
                continuation.resume(with: Result { try body() })
            }
        }
    }

    static func sameFolder(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    public func agentList(vault: URL) async throws -> [AgentNoteEntry] {
        try await onQueue(vault: vault) {
            return try self.agentRecords().map(Self.entry(for:))
        }
    }

    public func agentSearch(query: String, vault: URL, diskOnly: Set<String>) async throws -> AgentSearchOutcome {
        try await onQueue(vault: vault) {
            var matches: [AgentSearchMatch] = []
            var notSearched = 0
            // API results are disk snapshots. The switcher index can contain unsaved buffers or
            // cached evicted bodies, and its reader follows links; neither is an API source.
            let records = try self.agentRecords()
            for record in records {
                if record.text == nil { notSearched += 1 }
                guard let hit = NoteSearch.match(record: record, query: query) else { continue }
                let matchedIn = hit.score >= 1_000 ? "title" : hit.score >= 500 && hit.snippet == nil ? "filename" : "body"
                matches.append(AgentSearchMatch(
                    entry: Self.entry(for: record),
                    matchedIn: matchedIn,
                    snippet: hit.snippet.map { SearchHit.Snippet(before: $0.pre, match: $0.hit, after: $0.post) },
                    score: hit.score
                ))
            }
            matches.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.entry.modified != $1.entry.modified { return $0.entry.modified > $1.entry.modified }
                return $0.entry.filename < $1.entry.filename
            }
            return AgentSearchOutcome(matches: matches, notesTotal: records.count, bodiesNotSearched: notSearched)
        }
    }

    public func agentRead(filename: String, vault: URL, download: Bool) async throws -> AgentDiskNote {
        try NotePathPolicy.validate(filename)
        let availability = try await onQueue(vault: vault) { () throws -> NoteAvailability in
            let url = self.vaultURL.appendingPathComponent(filename)
            // A symlink or a directory is not "missing", whatever the resource values say about it.
            var info = stat()
            if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFREG {
                throw AgentFailure(.invalidNoteRef, "not a regular note file")
            }
            return self.agentAvailability(url)
        }
        switch availability {
        case .missing:
            throw AgentFailure(.noteNotFound, "the note no longer exists; list or search again")
        case .evicted:
            guard download else {
                throw AgentFailure(
                    .noteNotAvailable, "the note is in iCloud and not downloaded; read it with download: true",
                    details: ["availability": "evicted"]
                )
            }
            try await materializeForAgent(filename: filename, vault: vault)
        case .available:
            break
        }
        return try await onQueue(vault: vault) {
            let data = try VaultIO.agentRead(self.vaultURL.appendingPathComponent(filename))
            guard let raw = String(data: data, encoding: .utf8) else {
                throw AgentFailure(.noteNotAvailable, "the note is not UTF-8 text", details: ["reason": "not_utf8"])
            }
            let text = MarkdownDocument.normalizeTrailingNewline(raw)
            return AgentDiskNote(filename: filename, rawHash: ContentHash.of(data), text: text)
        }
    }

    /// Waits for iCloud on the download queue — never on the vault queue, where it would hold up
    /// every save behind a network fetch.
    private func materializeForAgent(filename: String, vault: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard Self.sameFolder(self.vaultURL, vault) else {
                    continuation.resume(throwing: AgentFailure(.vaultChanged, "the notes folder changed before download"))
                    return
                }
                let url = vault.appendingPathComponent(filename)
                self.downloads.async {
                    do {
                        try self.agentMaterialize(url, AgentLimits.downloadTimeout - 5)
                        continuation.resume()
                    } catch VaultError.downloadTimedOut {
                        continuation.resume(throwing: AgentFailure(.downloadTimeout, "iCloud did not finish downloading the note in time"))
                    } catch {
                        continuation.resume(throwing: AgentFailure(.noteNotAvailable, "iCloud could not download the note: \(error)"))
                    }
                }
            }
        }
    }

    public func agentReplace(filename: String, vault: URL, expectedHash: String, text: String) async throws -> String {
        try NotePathPolicy.validate(filename)
        return try await onQueue(vault: vault) {
            if self.writeDelayForTesting > 0 { Thread.sleep(forTimeInterval: self.writeDelayForTesting) }
            let hash = try VaultIO.agentReplace(
                text: text, at: self.vaultURL.appendingPathComponent(filename),
                expectedHash: expectedHash, gate: self.writeGate, gateTimeout: self.writeGateTimeout
            )
            self.index.update(filename: filename, text: MarkdownDocument.normalizeTrailingNewline(text), modified: Date())
            return hash
        }
    }

    public func agentReserveName(text: String, vault: URL, excluding: Set<String>) async throws -> String {
        try await onQueue(vault: vault) {
            let existing = Set((try VaultIO.listNotes(in: self.vaultURL)).map(\.lastPathComponent))
            return NoteFilename.unique(
                title: MarkdownDocument.title(of: text), date: Date(), existing: existing.union(excluding)
            )
        }
    }

    public func agentCreate(filename: String, vault: URL, text: String) async throws -> String {
        try NotePathPolicy.validate(filename)
        return try await onQueue(vault: vault) {
            let hash = try VaultIO.agentCreate(
                text: text, at: self.vaultURL.appendingPathComponent(filename), gate: self.writeGate,
                gateTimeout: self.writeGateTimeout
            )
            self.index.update(filename: filename, text: MarkdownDocument.normalizeTrailingNewline(text), modified: Date())
            return hash
        }
    }

    public func agentHash(filename: String, vault: URL) async throws -> String? {
        try NotePathPolicy.validate(filename)
        return try await onQueue(vault: vault) {
            try VaultIO.agentHash(self.vaultURL.appendingPathComponent(filename))
        }
    }

    /// Reads only bounded, regular files directly in the vault. An evicted or unreadable body stays
    /// absent and is included in search coverage, rather than using a stale cached body.
    private func agentRecords() throws -> [NoteRecord] {
        try VaultIO.listNotes(in: vaultURL).compactMap { url in
            guard (try? NotePathPolicy.validate(url.lastPathComponent)) != nil else { return nil }
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            let availability = self.agentAvailability(url)
            let text: String?
            if availability == .available, let data = try? VaultIO.agentRead(url) {
                text = String(data: data, encoding: .utf8)
            } else { text = nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return NoteRecord(filename: url.lastPathComponent, modified: modified,
                              title: text.map(MarkdownDocument.title(of:)) ?? NoteFilename.title(from: url.lastPathComponent) ?? "",
                              preview: "", text: text, availability: availability)
        }
    }

    private static func entry(for record: NoteRecord) -> AgentNoteEntry {
        let evicted: Bool
        if case .evicted = record.availability { evicted = true } else { evicted = false }
        return AgentNoteEntry(
            filename: record.filename,
            title: record.title,
            modified: record.modified,
            evicted: evicted,
            hasConflictMarkers: record.text.map(ConflictMarkers.isPresent(in:)) ?? false
        )
    }
}
