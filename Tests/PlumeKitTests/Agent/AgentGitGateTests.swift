import Foundation
import PlumeKit

/// Git sync and API writes take turns on the working tree, in a real repository.
func runAgentGitGateTests() {

    Check.suite("Agent · Git gate") {

        Check.test("a Git commit waits while an API write holds the working tree, then runs") {
            let vault = FileManager.default.temporaryDirectory.appendingPathComponent("gitgate-\(UUID().uuidString)")
            try! FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["init", "-q", vault.path]
            try! git.run()
            git.waitUntilExit()
            try! Data("# Note\n".utf8).write(to: vault.appendingPathComponent("2026-01-01-1200-note.md"))

            let gate = VaultWriteGate()
            let engine = GitSyncEngine(vault: vault, remoteURL: "", gate: gate)
            guard engine.isRepository else { return Check.expect(false, "git init failed") }

            final class Flag: @unchecked Sendable {
                private let lock = NSLock()
                private var value = false
                var isSet: Bool { lock.withLock { value } }
                func set() { lock.withLock { value = true } }
            }
            let committed = Flag()
            let release = DispatchSemaphore(value: 0)
            let held = DispatchSemaphore(value: 0)
            Thread {
                gate.withGate {
                    held.signal()
                    release.wait()
                }
            }.start()
            held.wait()
            let done = DispatchSemaphore(value: 0)
            Thread {
                if engine.snapshot() { committed.set() }
                done.signal()
            }.start()
            Thread.sleep(forTimeInterval: 0.4)
            Check.expect(!committed.isSet, "the commit ran while the gate was held")
            release.signal()
            Check.equal(done.wait(timeout: .now() + 10), .success)
            Check.expect(committed.isSet, "the commit runs once the gate is free")
        }
    }
}
