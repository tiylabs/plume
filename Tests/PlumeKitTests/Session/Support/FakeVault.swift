import Foundation
import PlumeKit

/// An in-memory vault whose answers wait for the test.
///
/// The real service does its I/O on a private queue and answers on the main thread some time later;
/// nearly every guard in `NoteSession` exists because of what can happen *between* the question and
/// the answer. So this one records each operation as it is asked, does nothing, and only completes it
/// when the test says so. "A write is in flight" is then a state a test can sit in.
///
/// Each operation's effect on the file table is applied when it **completes**, which is what the
/// real queue does too, and in the order the test releases them.
/// Not `@MainActor`, because `VaultServicing` is not: the real service is called from the main thread
/// and runs on its own queue. The fake is only ever touched from the main thread (every test body
/// is), so its state needs no lock; each protocol method asserts that rather than assuming it.
final class FakeVault: VaultServicing, @unchecked Sendable {

    struct File {
        var text: String
        /// Bumped on every external change, so a hash can be told apart from the last one.
        var hash: String { ContentHash.of(MarkdownDocument.normalizeTrailingNewline(text)) }
        var evicted = false
    }

    /// What the test sees of an operation that has been asked and not yet answered.
    enum Op: Equatable {
        case load(String)
        case download(String)
        case write(text: String, to: String, expectedHash: String?)
        case create(text: String)
        case rename(from: String, to: String)
        case renameFollowingTitle(String, title: String)
        case delete(String)
        case keepDeleted(String, text: String)
        case forgetIndexed(String)
        case diskState(String)
        case harvestConflicts(String)
        case findRenamed(String)
        case rows
        case present
        case noteBufferChanged(String)
    }

    var files: [String: File] = [:]
    private(set) var pending: [(op: Op, finish: @MainActor () -> Void)] = []
    /// Every operation ever asked, in order, answered or not.
    private(set) var log: [Op] = []

    /// What `rows` answers, newest first. Tests set it when they care about `openLastUsed`.
    var rowOrder: [String] = []
    /// Conflict siblings a write is told to produce, by source filename.
    var conflictSibling: [String: String] = [:]
    /// Notes iCloud has losing versions for.
    var iCloudConflicts: [String: [String]] = [:]
    /// `findRenamed` answers.
    var renamedTo: [String: String] = [:]
    var failNextCreate = false
    var nameCounter = 0

    init() {}

    // MARK: - Test control

    var pendingOps: [Op] { pending.map(\.op) }

    /// Answers the oldest pending operation matching `where`, or the oldest overall.
    @MainActor @discardableResult
    func release(where predicate: (Op) -> Bool = { _ in true }) -> Op? {
        guard let index = pending.firstIndex(where: { predicate($0.op) }) else { return nil }
        let entry = pending.remove(at: index)
        entry.finish()
        return entry.op
    }

    @MainActor func releaseAll() {
        while !pending.isEmpty { release() }
    }

    func count(where predicate: (Op) -> Bool) -> Int { log.filter(predicate).count }
    func writes(to filename: String? = nil) -> [(text: String, expected: String?)] {
        log.compactMap { op in
            if case .write(let text, let to, let expected) = op, filename == nil || to == filename {
                return (text, expected)
            }
            return nil
        }
    }

    private func ask(_ op: Op, _ finish: @escaping @MainActor () -> Void) {
        log.append(op)
        pending.append((op, finish))
    }

    private func uniqueName(for text: String) -> String {
        nameCounter += 1
        let title = MarkdownDocument.title(of: text)
        let slug = title.isEmpty ? "untitled" : NoteFilename.slug(from: title)
        return String(format: "2026-01-01-%04d-%@.md", nameCounter, slug)
    }

    // MARK: - VaultServicing

    func setVault(_ url: URL) {}

    func rows(
        query: String, state: AppState, current: String?, order: Settings.NoteOrder, refresh: Bool,
        completion: @escaping @MainActor (VaultSnapshot) -> Void
    ) {
        ask(.rows) {
            let rows = self.rowOrder.map { SwitcherRow(filename: $0, title: $0, time: "", preview: "") }
            completion(VaultSnapshot(rows: rows, total: rows.count, query: query))
        }
    }

    func present(completion: @escaping @MainActor (Set<String>) -> Void) {
        ask(.present) { completion(Set(self.files.keys)) }
    }

    func load(_ filename: String, completion: @escaping @MainActor (VaultLoadResult) -> Void) {
        ask(.load(filename)) {
            guard let file = self.files[filename] else { return completion(.missing) }
            if file.evicted { return completion(.downloading(logicalSize: file.text.utf8.count)) }
            completion(.loaded(text: file.text, hash: file.hash))
        }
    }

    func download(_ filename: String, completion: @escaping @MainActor (VaultLoadResult) -> Void) {
        ask(.download(filename)) {
            guard var file = self.files[filename] else { return completion(.missing) }
            file.evicted = false
            self.files[filename] = file
            completion(.loaded(text: file.text, hash: file.hash))
        }
    }

    func diskState(_ filename: String, completion: @escaping @MainActor (VaultDiskState) -> Void) {
        ask(.diskState(filename)) {
            guard let file = self.files[filename] else { return completion(.missing) }
            completion(file.evicted ? .evicted : .available(hash: file.hash))
        }
    }

    func harvestConflicts(_ filename: String, completion: @escaping @MainActor ([String]) -> Void) {
        ask(.harvestConflicts(filename)) { completion(self.iCloudConflicts[filename] ?? []) }
    }

    func write(
        text: String, to filename: String, expectedHash: String?,
        completion: @escaping @MainActor (VaultWriteResult) -> Void
    ) {
        ask(.write(text: text, to: filename, expectedHash: expectedHash)) {
            let current = self.files[filename]
            // The real `VaultIO.write`: a file that changed (or was evicted) underneath goes to a
            // sibling and the original is left alone.
            if let expectedHash, let current, current.evicted || current.hash != expectedHash {
                let sibling = self.conflictSibling[filename] ?? filename.replacingOccurrences(of: ".md", with: "-conflict.md")
                self.files[sibling] = File(text: text)
                return completion(.conflicted(sibling: sibling, hash: self.files[sibling]!.hash))
            }
            self.files[filename] = File(text: text)
            completion(.written(hash: self.files[filename]!.hash))
        }
    }

    func create(
        text: String,
        completion: @escaping @MainActor (Result<(filename: String, hash: String), any Error>) -> Void
    ) {
        ask(.create(text: text)) {
            if self.failNextCreate {
                self.failNextCreate = false
                return completion(.failure(VaultError.coordination("disk full")))
            }
            let name = self.uniqueName(for: text)
            self.files[name] = File(text: text)
            completion(.success((filename: name, hash: self.files[name]!.hash)))
        }
    }

    func rename(
        _ filename: String, to newName: String, text: String,
        completion: @escaping @MainActor (VaultRenameResult) -> Void
    ) {
        ask(.rename(from: filename, to: newName)) {
            guard filename != newName, self.files[filename] != nil, self.files[newName] == nil else {
                return completion(.declined)
            }
            self.files[newName] = self.files.removeValue(forKey: filename)
            completion(.renamed(to: newName))
        }
    }

    func renameFollowingTitle(
        _ filename: String, title: String, text: String,
        completion: @escaping @MainActor (VaultRenameResult) -> Void
    ) {
        ask(.renameFollowingTitle(filename, title: title)) {
            let existing = Set(self.files.keys)
            guard let wanted = NoteNaming.rename(current: filename, title: title, existing: existing),
                  self.files[filename] != nil
            else { return completion(.declined) }
            self.files[wanted] = self.files.removeValue(forKey: filename)
            completion(.renamed(to: wanted))
        }
    }

    func findRenamed(
        of filename: String, among candidates: [String], matching hash: String,
        completion: @escaping @MainActor (String?) -> Void
    ) {
        ask(.findRenamed(filename)) { completion(self.renamedTo[filename]) }
    }

    func delete(_ filename: String, completion: @escaping @MainActor (Bool) -> Void) {
        ask(.delete(filename)) {
            let existed = self.files.removeValue(forKey: filename) != nil
            completion(existed)
        }
    }

    func keepDeleted(_ filename: String, text: String, completion: @escaping @MainActor (Bool) -> Void) {
        ask(.keepDeleted(filename, text: text)) {
            self.files.removeValue(forKey: filename)
            completion(true)
        }
    }

    func forgetIndexed(_ filename: String, completion: @escaping @MainActor () -> Void) {
        ask(.forgetIndexed(filename)) { completion() }
    }

    func deletedRows(completion: @escaping @MainActor ([SwitcherRow]) -> Void) { ask(.rows) { completion([]) } }
    func restoreDeleted(_ storedName: String, completion: @escaping @MainActor (String?) -> Void) { ask(.rows) { completion(nil) } }
    func forgetDeleted(_ storedName: String, completion: @escaping @MainActor (Bool) -> Void) { ask(.rows) { completion(false) } }

    func noteBufferChanged(filename: String, text: String) { log.append(.noteBufferChanged(filename)) }
}
