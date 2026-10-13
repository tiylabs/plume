import Foundation

/// What the panel needs from the vault, as a protocol, so it depends on a promise rather than on the
/// class that keeps it. `VaultService` is the real one; a test can supply another.
///
/// Every operation takes a completion that runs on the main actor, because the real service does its
/// I/O on a private serial queue and hands the answer back. The list is exactly what
/// `PanelController` calls — no more — so it is also a map of how much of the vault the panel
/// touches.
public protocol VaultServicing: AnyObject, Sendable {

    func setVault(_ url: URL)

    func rows(
        query: String,
        state: AppState,
        current: String?,
        order: Settings.NoteOrder,
        refresh: Bool,
        completion: @escaping @MainActor (VaultSnapshot) -> Void
    )

    func present(completion: @escaping @MainActor (Set<String>) -> Void)

    func load(_ filename: String, completion: @escaping @MainActor (VaultLoadResult) -> Void)
    func download(_ filename: String, completion: @escaping @MainActor (VaultLoadResult) -> Void)
    func diskState(_ filename: String, completion: @escaping @MainActor (VaultDiskState) -> Void)
    func harvestConflicts(_ filename: String, completion: @escaping @MainActor ([String]) -> Void)

    func write(
        text: String,
        to filename: String,
        expectedHash: String?,
        completion: @escaping @MainActor (VaultWriteResult) -> Void
    )

    func create(
        text: String,
        completion: @escaping @MainActor (Result<(filename: String, hash: String), any Error>) -> Void
    )

    func rename(
        _ filename: String,
        to newName: String,
        text: String,
        completion: @escaping @MainActor (VaultRenameResult) -> Void
    )

    func renameFollowingTitle(
        _ filename: String,
        title: String,
        text: String,
        completion: @escaping @MainActor (VaultRenameResult) -> Void
    )

    func findRenamed(
        of filename: String,
        among candidates: [String],
        matching hash: String,
        completion: @escaping @MainActor (String?) -> Void
    )

    func delete(_ filename: String, completion: @escaping @MainActor (Bool) -> Void)
    func keepDeleted(_ filename: String, text: String, completion: @escaping @MainActor (Bool) -> Void)
    func forgetIndexed(_ filename: String, completion: @escaping @MainActor () -> Void)

    func deletedRows(completion: @escaping @MainActor ([SwitcherRow]) -> Void)
    func restoreDeleted(_ storedName: String, completion: @escaping @MainActor (String?) -> Void)
    func forgetDeleted(_ storedName: String, completion: @escaping @MainActor (Bool) -> Void)

    func noteBufferChanged(filename: String, text: String)
}

extension VaultServicing {
    /// The panel never skips the refresh, and `order` defaults to most-recently-modified, as it
    /// always has on the concrete service.
    public func rows(
        query: String,
        state: AppState,
        current: String?,
        order: Settings.NoteOrder = .modified,
        completion: @escaping @MainActor (VaultSnapshot) -> Void
    ) {
        rows(query: query, state: state, current: current, order: order, refresh: true, completion: completion)
    }
}
