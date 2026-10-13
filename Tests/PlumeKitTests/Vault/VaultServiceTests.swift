import Foundation
import PlumeKit

/// Result holder for a completion that arrives on the main queue.
@MainActor
private final class Box<T> {
    var value: T?
}

/// Starts an operation and spins the main run loop until its completion has run. The service does
/// its I/O on a private queue and answers on the main one, so the suite has to let the main queue
/// turn; five seconds is far longer than any of these needs and only matters when something hangs.
@MainActor
private func finish<T>(
    _ start: (@escaping @MainActor (T) -> Void) -> Void,
    file: StaticString = #fileID, line: UInt = #line
) -> T? {
    let box = Box<T>()
    start { box.value = $0 }
    let deadline = Date().addingTimeInterval(5)
    while box.value == nil, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    Check.expect(box.value != nil, "the completion never ran", file: file, line: line)
    return box.value
}

private struct Fixture {
    let vault: URL
    let deleted: URL
    let service: VaultService

    @MainActor init() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vault-service-\(UUID().uuidString)")
        vault = root.appendingPathComponent("vault")
        deleted = root.appendingPathComponent("deleted")
        try? FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        service = VaultService(vault: vault, deletedStore: deleted)
    }

    func text(of name: String) -> String? {
        try? String(contentsOf: vault.appendingPathComponent(name), encoding: .utf8)
    }

    func notes() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: vault.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
    }
}

func runVaultServiceTests() {
    Check.mainSuite("VaultService") {

        Check.mainTest("create names the note from its first line and returns the hash of what landed") {
            let f = Fixture()
            guard let result = finish({ f.service.create(text: "# Groceries\n\nmilk", completion: $0) }),
                  case .success(let created) = result else {
                Check.expect(false, "create failed"); return
            }
            Check.expect(created.filename.hasSuffix("-groceries.md"), "named from the title: \(created.filename)")
            Check.equal(f.text(of: created.filename), "# Groceries\n\nmilk\n", "one trailing newline is added")
            Check.equal(f.notes(), [created.filename])
        }

        Check.mainTest("write with the expected hash replaces the note and returns the new hash") {
            let f = Fixture()
            guard case .success(let created)? = finish({ f.service.create(text: "one", completion: $0) }) else {
                Check.expect(false, "create failed"); return
            }
            let result = finish { f.service.write(
                text: "two", to: created.filename, expectedHash: created.hash, completion: $0
            ) }
            guard case .written(let hash)? = result else {
                Check.expect(false, "expected .written, got \(String(describing: result))"); return
            }
            Check.notEqual(hash, created.hash)
            Check.equal(f.text(of: created.filename), "two\n")
        }

        Check.mainTest("a stale expectedHash writes a conflict copy and leaves the other writer's file alone") {
            let f = Fixture()
            guard case .success(let created)? = finish({ f.service.create(text: "mine", completion: $0) }) else {
                Check.expect(false, "create failed"); return
            }
            // Someone else changes the file after we last read it.
            try? "theirs\n".write(to: f.vault.appendingPathComponent(created.filename), atomically: true, encoding: .utf8)

            let result = finish { f.service.write(
                text: "mine, edited", to: created.filename, expectedHash: created.hash, completion: $0
            ) }
            guard case .conflicted(let sibling, _)? = result else {
                Check.expect(false, "expected .conflicted, got \(String(describing: result))"); return
            }
            Check.equal(f.text(of: created.filename), "theirs\n", "their version is untouched")
            Check.equal(f.text(of: sibling), "mine, edited\n", "our text survives as a sibling")
            Check.equal(f.notes().count, 2)
        }

        Check.mainTest("a write followed at once by a delete leaves the latest text in Recently Deleted") {
            let f = Fixture()
            guard case .success(let created)? = finish({ f.service.create(text: "draft", completion: $0) }) else {
                Check.expect(false, "create failed"); return
            }
            // Both enqueued before either answers: the serial queue is what orders them. The write is
            // held for a moment so that a delete which escaped the queue would overtake it.
            f.service.writeDelayForTesting = 0.15
            let wrote = Box<VaultWriteResult>()
            let deletedIt = Box<Bool>()
            f.service.write(text: "the last thing typed", to: created.filename, expectedHash: created.hash) {
                wrote.value = $0
            }
            f.service.delete(created.filename) { deletedIt.value = $0 }
            let deadline = Date().addingTimeInterval(5)
            while deletedIt.value == nil, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }

            Check.equal(deletedIt.value, true)
            Check.expect(f.text(of: created.filename) == nil, "the note left the vault")
            let kept = RecentlyDeleted.list(in: f.deleted)
            Check.equal(kept.count, 1)
            let text = kept.first.flatMap {
                try? String(contentsOf: f.deleted.appendingPathComponent($0.storedName), encoding: .utf8)
            }
            Check.equal(text, "the last thing typed\n", "the write ran before the delete, not after it")
        }

        Check.mainTest("present reflects a file added from outside, and one removed") {
            let f = Fixture()
            Check.equal(finish({ f.service.present(completion: $0) }), [])
            try? "x\n".write(to: f.vault.appendingPathComponent("2026-01-01-0000-outside.md"), atomically: true, encoding: .utf8)
            Check.equal(finish({ f.service.present(completion: $0) }), ["2026-01-01-0000-outside.md"])
            try? FileManager.default.removeItem(at: f.vault.appendingPathComponent("2026-01-01-0000-outside.md"))
            Check.equal(finish({ f.service.present(completion: $0) }), [])
        }

        Check.mainTest("load reports missing, loaded, and gives the hash a write can be checked against") {
            let f = Fixture()
            guard case .missing? = finish({ f.service.load("nope.md", completion: $0) }) else {
                Check.expect(false, "expected .missing"); return
            }
            guard case .success(let created)? = finish({ f.service.create(text: "hello", completion: $0) }),
                  case .loaded(let text, let hash)? = finish({ f.service.load(created.filename, completion: $0) }) else {
                Check.expect(false, "expected .loaded"); return
            }
            Check.equal(text, "hello\n")
            Check.equal(hash, created.hash, "load and create agree on the hash of the same bytes")
        }

        Check.mainTest("rows lists notes and find-by-title reaches a note created a moment ago") {
            let f = Fixture()
            _ = finish { f.service.create(text: "# Zebra notes", completion: $0) }
            let snapshot = finish { f.service.rows(query: "zebra", state: AppState(), current: nil, completion: $0) }
            Check.equal(snapshot?.total, 1)
            Check.equal(snapshot?.rows.count, 1)
            Check.equal(snapshot?.rows.first?.title, "Zebra notes")
        }

        Check.mainTest("rename moves the file, declines a taken name, and declines a missing source") {
            let f = Fixture()
            guard case .success(let a)? = finish({ f.service.create(text: "alpha", completion: $0) }),
                  case .success(let b)? = finish({ f.service.create(text: "beta", completion: $0) }) else {
                Check.expect(false, "create failed"); return
            }
            guard case .renamed(let to)? = finish({ f.service.rename(a.filename, to: "renamed.md", text: "alpha", completion: $0) }) else {
                Check.expect(false, "expected .renamed"); return
            }
            Check.equal(to, "renamed.md")
            Check.expect(f.text(of: a.filename) == nil)
            Check.equal(f.text(of: "renamed.md"), "alpha\n")

            guard case .declined? = finish({ f.service.rename(b.filename, to: "renamed.md", text: "beta", completion: $0) }) else {
                Check.expect(false, "a taken name must be declined, never overwritten"); return
            }
            Check.equal(f.text(of: "renamed.md"), "alpha\n")
            guard case .declined? = finish({ f.service.rename("ghost.md", to: "x.md", text: "", completion: $0) }) else {
                Check.expect(false, "a missing source must be declined"); return
            }
        }

        Check.mainTest("restoreDeleted brings a deleted note back into the vault and the index") {
            let f = Fixture()
            guard case .success(let created)? = finish({ f.service.create(text: "# Back again", completion: $0) }) else {
                Check.expect(false, "create failed"); return
            }
            _ = finish { f.service.delete(created.filename, completion: $0) }
            guard let stored = RecentlyDeleted.list(in: f.deleted).first?.storedName else {
                Check.expect(false, "nothing in Recently Deleted"); return
            }
            let restored = finish { f.service.restoreDeleted(stored, completion: $0) }
            Check.expect(restored != nil && restored! != nil, "restore returned a name")
            if let name = restored ?? nil { Check.equal(f.text(of: name), "# Back again\n") }
            let snapshot = finish { f.service.rows(query: "", state: AppState(), current: nil, completion: $0) }
            Check.equal(snapshot?.total, 1, "the restored note is listed without waiting for another refresh")
        }
    }
}
