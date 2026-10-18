import Darwin
import Foundation

/// The strict file operations behind the agent API.
///
/// `VaultIO.write` is built for the panel, and two of its behaviours are right there and wrong here:
/// `expectedHash: nil` writes unconditionally, and a missing file is recreated ("a note deleted
/// elsewhere comes back with what you typed"). For a write an agent asked for, a missing file means
/// the note is gone and the agent must find out, and a changed file means it must read again — so
/// these never recreate, never write a conflict sibling, and never follow a symlink.
extension VaultIO {

    /// A note's bytes, as the agent API reads them: no symlinks, no materialising, no oversize.
    ///
    /// Opened with `O_NOFOLLOW` and checked with `fstat` on the descriptor actually read, so the
    /// check and the read are about the same file. Reads under coordination, like `loadText`.
    public static func agentRead(_ url: URL) throws -> Data {
        try checkPlainFile(url)
        var result: Result<Data, AgentFailure> = .failure(AgentFailure(.saveFailed, "no read"))
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: url, options: [.withoutChanges], error: &coordinationError
        ) { actual in
            result = Result { try readNoFollow(actual) }.mapError(asAgentFailure)
        }
        if let coordinationError {
            throw AgentFailure(.saveFailed, coordinationError.localizedDescription)
        }
        return try result.get()
    }

    /// Replaces a note's contents only if its bytes still hash to `expectedHash`.
    ///
    /// The comparison and the replace happen inside one coordinated write, so a coordinated writer
    /// cannot slip between them; the gate keeps Git's merge out of the same window. A missing or
    /// evicted file is an error, never a re-creation; a mismatch is `VERSION_CONFLICT`, never a
    /// sibling. Returns the hash of the bytes now on disk.
    public static func agentReplace(
        text: String, at url: URL, expectedHash: String, gate: VaultWriteGate,
        gateTimeout: TimeInterval = AgentLimits.worktreeGateTimeout
    ) throws -> String {
        guard !expectedHash.isEmpty else { throw AgentFailure(.invalidRequest, "expected hash is required") }
        try NotePathPolicy.validate(url.lastPathComponent)
        let data = Data(MarkdownDocument.normalizeTrailingNewline(text).utf8)
        let newHash = ContentHash.of(data)
        let written: Result<String, AgentFailure>? = gate.withGate(timeout: gateTimeout) {
            coordinatedWrite(url) { actual in
                try checkPlainFile(actual)
                let onDisk = try readNoFollow(actual)
                guard ContentHash.of(onDisk) == expectedHash else {
                    throw AgentFailure(.versionConflict, "the note changed since it was read; read it again and redo the change")
                }
                try data.write(to: actual, options: [.atomic])
                return newHash
            }
        }
        guard let written else { throw gateBusy() }
        return try written.get()
    }

    /// Creates a note at exactly `url`, failing if anything is already there.
    ///
    /// The name was reserved on the vault queue, but a reservation binds only this app; a shell, a
    /// sync client or Git may still have put a file there. So the bytes go to a hidden temporary in
    /// the vault and are published with `renamex_np(RENAME_EXCL)` — atomic and refusing to
    /// overwrite. The temporary is a dot-file so the watcher and the index ignore it.
    public static func agentCreate(
        text: String, at url: URL, gate: VaultWriteGate,
        gateTimeout: TimeInterval = AgentLimits.worktreeGateTimeout
    ) throws -> String {
        try NotePathPolicy.validate(url.lastPathComponent)
        let data = Data(MarkdownDocument.normalizeTrailingNewline(text).utf8)
        let hash = ContentHash.of(data)
        let written: Result<String, AgentFailure>? = gate.withGate(timeout: gateTimeout) {
            coordinatedWrite(url) { actual in
                let folder = actual.deletingLastPathComponent()
                let temporary = folder.appendingPathComponent(".plume-cli-\(UUID().uuidString).tmp")
                try data.write(to: temporary, options: [.withoutOverwriting])
                guard renamex_np(temporary.path, actual.path, UInt32(RENAME_EXCL)) == 0 else {
                    let code = errno
                    unlink(temporary.path)
                    if code == EEXIST {
                        throw AgentFailure(
                            .saveFailed, "another program created a file with this name at the same moment; retry",
                            details: ["reason": "name_taken"]
                        )
                    }
                    throw AgentFailure(.saveFailed, "could not create the note: \(String(cString: strerror(code)))")
                }
                return hash
            }
        }
        guard let written else { throw gateBusy() }
        return try written.get()
    }

    /// The raw-byte hash of a note, or nil if there is no such file. For crash recovery.
    public static func agentHash(_ url: URL) throws -> String? {
        switch availability(of: url) {
        case .missing: return nil
        case .evicted: throw AgentFailure(.noteNotAvailable, "the note is in iCloud and not downloaded")
        case .available: return ContentHash.of(try agentRead(url))
        }
    }

    // MARK: - Pieces

    private static func coordinatedWrite(
        _ url: URL, _ body: (URL) throws -> String
    ) -> Result<String, AgentFailure> {
        var result: Result<String, AgentFailure> = .failure(AgentFailure(.saveFailed, "no write"))
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: url, options: .forReplacing, error: &coordinationError
        ) { actual in
            result = Result { try body(actual) }.mapError(asAgentFailure)
        }
        if let coordinationError {
            return .failure(AgentFailure(.saveFailed, coordinationError.localizedDescription))
        }
        return result
    }

    /// Present, a regular file, not a symlink, and not an iCloud placeholder.
    static func checkPlainFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw AgentFailure(.noteNotFound, "the note no longer exists; list or search again")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw AgentFailure(.invalidNoteRef, "not a regular note file")
        }
        if case .evicted = availability(of: url) {
            throw AgentFailure(
                .noteNotAvailable, "the note is in iCloud and not downloaded; read it with download: true",
                details: ["availability": "evicted"]
            )
        }
        guard Int(info.st_size) <= AgentLimits.noteMaxBytes else {
            throw AgentFailure(.contentTooLarge, "the note is larger than \(AgentLimits.noteMaxBytes) bytes")
        }
    }

    /// Reads through a descriptor opened without following symlinks, with iCloud materialisation off
    /// for this thread — a placeholder fails at once instead of blocking for seconds.
    static func readNoFollow(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { throw AgentFailure(.noteNotFound, "the note no longer exists; list or search again") }
            if errno == ELOOP { throw AgentFailure(.invalidNoteRef, "not a regular note file") }
            throw AgentFailure(.noteNotAvailable, "could not open the note: \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw AgentFailure(.invalidNoteRef, "not a regular note file")
        }
        guard Int(info.st_size) <= AgentLimits.noteMaxBytes else {
            throw AgentFailure(.contentTooLarge, "the note is larger than \(AgentLimits.noteMaxBytes) bytes")
        }
        let previous = getiopolicy_np(ioPolicyTypeMaterializeDatalessFiles, ioPolicyScopeThread)
        setiopolicy_np(ioPolicyTypeMaterializeDatalessFiles, ioPolicyScopeThread, ioPolicyMaterializeOff)
        defer { setiopolicy_np(ioPolicyTypeMaterializeDatalessFiles, ioPolicyScopeThread, previous) }
        do {
            let data = try handle.read(upToCount: AgentLimits.noteMaxBytes + 1) ?? Data()
            guard data.count <= AgentLimits.noteMaxBytes else {
                throw AgentFailure(.contentTooLarge, "the note grew beyond the size limit while reading")
            }
            return data
        } catch let failure as AgentFailure { throw failure
        } catch {
            throw AgentFailure(.noteNotAvailable, "the note could not be read without downloading it", details: ["availability": "evicted"])
        }
    }

    private static func gateBusy() -> AgentFailure {
        AgentFailure(.noteBusy, "Git sync is merging into the notes folder; retry in a few seconds", details: ["reason": AgentBusyReason.syncing.rawValue])
    }

    private static func asAgentFailure(_ error: any Error) -> AgentFailure {
        (error as? AgentFailure) ?? AgentFailure(.saveFailed, String(describing: error))
    }
}
