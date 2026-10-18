import CryptoKit
import Foundation

/// The record of every agent write: what was asked, where it stands, and the text before and after.
///
/// It exists because a note file and a "this succeeded" record cannot be replaced in one atomic
/// step. The order is what makes the pair recoverable instead: the `prepared` record — target,
/// reserved name, before and after text — is durable **before** the note changes, and the `saved`
/// record is durable **before** success is reported. A crash anywhere in between leaves enough on
/// disk for the next launch to tell "not yet written" from "written" from "something else changed
/// it", and to say which (`recoverableOperations`).
///
/// One JSON file per operation, named by a hash of the authorisation generation and request ID, so
/// the idempotency lookup is one `stat` rather than a scan. Snapshots are separate files beside it.
/// Everything is `0600` in a `0700` folder under Application Support — never in the vault.
public final class OperationJournal: @unchecked Sendable {

    public enum Snapshot: String, Sendable {
        case before
        case after
    }

    public let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Records

    static func key(generation: String, requestID: String) -> String {
        let digest = SHA256.hash(data: Data("\(generation)\n\(requestID)".utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func recordURL(generation: String, requestID: String) -> URL {
        directory.appendingPathComponent(Self.key(generation: generation, requestID: requestID) + ".json")
    }

    public func record(generation: String, requestID: String) -> OperationRecord? {
        lock.lock()
        defer { lock.unlock() }
        return read(recordURL(generation: generation, requestID: requestID))
    }

    /// A damaged record cannot mean "never received": treating it that way would run a write twice.
    public func checkedRecord(generation: String, requestID: String) throws -> OperationRecord? {
        lock.lock()
        defer { lock.unlock() }
        let url = recordURL(generation: generation, requestID: requestID)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG,
              let record = read(url), record.generation == generation, record.requestID == requestID else {
            throw AgentFailure(.outcomeUnknown, "the operation record is damaged; inspect the note before continuing", requestID: requestID)
        }
        return record
    }

    /// Durable on return. Throws rather than pretending: a write whose record did not land must not
    /// go ahead, and a success whose record did not land must not be reported.
    public func save(_ record: OperationRecord) throws {
        let encoder = AgentJSON.prettyEncoder
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(record)
        lock.lock()
        defer { lock.unlock() }
        try DurableFile.write(data, to: recordURL(generation: record.generation, requestID: record.requestID))
    }

    public func saveSnapshot(_ text: String, of operationID: String, _ which: Snapshot) throws {
        lock.lock()
        defer { lock.unlock() }
        try DurableFile.write(Data(text.utf8), to: snapshotURL(operationID, which))
    }

    public func snapshot(of operationID: String, _ which: Snapshot) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: snapshotURL(operationID, which)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func snapshotURL(_ operationID: String, _ which: Snapshot) -> URL {
        // The ID is ours (a UUID), but it is read back from a file a person can edit; refuse
        // anything that could name a path.
        let safe = operationID.filter { $0.isHexDigit || $0 == "-" }
        return directory.appendingPathComponent("\(safe).\(which.rawValue).md")
    }

    /// Every record, newest first. For Settings' recent writes and for recovery.
    public func all() -> [OperationRecord] {
        lock.lock()
        defer { lock.unlock() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .compactMap { read(directory.appendingPathComponent($0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Operations a previous run left mid-flight.
    public func unfinished() -> [OperationRecord] {
        all().filter { !$0.state.isTerminal }
    }

    public func operation(id: String) -> OperationRecord? {
        all().first { $0.operationID == id }
    }

    private func read(_ url: URL) -> OperationRecord? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= AgentLimits.ipcMaxFrameBytes,
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = AgentJSON.decoder
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return (try? decoder.decode(OperationRecord.self, from: data))
            ?? (try? AgentJSON.decoder.decode(OperationRecord.self, from: data))
    }

    // MARK: - Retention

    /// Drops snapshots of finished operations older than the full retention, and whole records
    /// older than the compact retention. Run at launch, alongside Recently Deleted's purge — Plume
    /// is not running most of the time, so there is no timer that could do it.
    ///
    /// The compact record outlives the snapshots on purpose: it is what stops a client retrying a
    /// weeks-old request ID from running it a second time.
    public func purge(now: Date = Date()) {
        for var record in all() where record.state.isTerminal {
            let age = now.timeIntervalSince(record.createdAt)
            if age > AgentLimits.operationCompactRetention {
                lock.lock()
                unlink(recordURL(generation: record.generation, requestID: record.requestID).path)
                lock.unlock()
                dropSnapshots(record.operationID)
            } else if age > AgentLimits.operationFullRetention, !record.compacted {
                dropSnapshots(record.operationID)
                record.compacted = true
                try? save(record)
            }
        }
    }

    private func dropSnapshots(_ operationID: String) {
        lock.lock()
        defer { lock.unlock() }
        unlink(snapshotURL(operationID, .before).path)
        unlink(snapshotURL(operationID, .after).path)
    }

    /// Everything, at the user's request. The caller also rotates the authorisation generation, so
    /// old request IDs cannot be retried against an empty journal.
    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names { unlink(directory.appendingPathComponent(name).path) }
    }
}

/// The digest that tells a retry from a different request under the same ID.
///
/// Over the typed request's canonical JSON (sorted keys), plus the vault it was bound to. Text is
/// hashed exactly as sent — not trimmed, not normalised — because `old_text` is matched exactly and
/// two requests differing by a trailing space are two different edits.
public enum OperationDigest {
    public static func of<T: Encodable>(_ request: T, vaultID: String) -> String {
        let body = (try? AgentJSON.encoder.encode(request)) ?? Data()
        var hasher = SHA256()
        hasher.update(data: Data(vaultID.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: body)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
