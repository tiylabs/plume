import Foundation

/// The switcher's rows for one query, with the vault's total note count.
public struct VaultSnapshot: Sendable {
    public var rows: [SwitcherRow]
    public var total: Int
    public var query: String

    public init(rows: [SwitcherRow], total: Int, query: String) {
        self.rows = rows
        self.total = total
        self.query = query
    }
}

public enum VaultLoadResult: Sendable {
    case loaded(text: String, hash: String)
    /// The note is an iCloud placeholder. The caller shows "downloading…" and calls
    /// `download(_:)`; it must not simply read the file, which would block for seconds.
    case downloading(logicalSize: Int)
    case missing
    case failed(String)
}

/// What is on disk right now, without materialising anything.
///
/// Used by the watcher to tell our own echo from someone else's write — and, since decision 105,
/// to notice that the open note has been evicted. This used to be `diskHash` returning an
/// optional, and `nil` meant "gone **or** evicted, not our call to make here": the caller simply
/// bailed, so if iCloud dataless-ed the note you were looking at, the panel went on showing stale
/// text with no banner and no way to know. "Downloading…" fired only on *open*, never mid-session.
public enum VaultDiskState: Sendable {
    case available(hash: String)
    case evicted
    case missing
    /// There, not evicted, and unreadable — a permissions problem or a torn write. The caller
    /// does nothing, which is what the old `nil` did for every one of these cases.
    case unreadable
}

public enum VaultWriteResult: Sendable {
    case written(hash: String)
    case conflicted(sibling: String, hash: String)
    case failed(String)
}

public enum VaultRenameResult: Sendable {
    case renamed(to: String)
    /// The name it wants is taken, or the file is not where we left it. Not an error the user
    /// needs told about — the name simply stays as it is.
    case declined
    case failed(String)
}
