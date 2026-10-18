import Foundation
import PlumeKit

/// iCloud-evicted notes through the agent API, using `VaultService`'s availability seams: list says
/// so, search does not read them, read refuses unless a download is allowed, and a download that
/// runs out of time says that.
@MainActor
func runAgentAvailabilityTests() {

    /// Which files the fake iCloud holds as placeholders, and how many downloads were asked for.
    final class Cloud: @unchecked Sendable {
        private let lock = NSLock()
        private var evicted: Set<String> = []
        private var downloads = 0
        var failDownload = false

        func evict(_ name: String) { lock.withLock { _ = evicted.insert(name) } }
        var downloadCount: Int { lock.withLock { downloads } }

        func availability(_ url: URL) -> NoteAvailability {
            let isEvicted = lock.withLock { evicted.contains(url.lastPathComponent) }
            return isEvicted ? .evicted(logicalSize: 10) : VaultIO.availability(of: url)
        }

        func materialize(_ url: URL) throws {
            try lock.withLock {
                downloads += 1
                if failDownload { throw VaultError.downloadTimedOut(url) }
                evicted.remove(url.lastPathComponent)
            }
        }
    }

    func rig() -> (AgentRig, Cloud) {
        let rig = AgentRig()
        let cloud = Cloud()
        rig.vault.agentAvailability = { cloud.availability($0) }
        rig.vault.agentMaterialize = { url, _ in try cloud.materialize(url) }
        return (rig, cloud)
    }

    Check.mainSuite("Agent · iCloud-evicted notes") {

        Check.mainTest("list marks an evicted note; search does not read its body and says so") {
            let (rig, cloud) = rig()
            rig.seed("2026-01-01-1200-here.md", "# Here\n\nzebra on disk\n")
            rig.seed("2026-01-01-1201-cloud-only.md", "# Cloud only\n\nzebra in the cloud\n")
            cloud.evict("2026-01-01-1201-cloud-only.md")

            let list = rig.ok(.listNotes, [:], as: ListNotesResult.self)!
            let cloudy = list.notes.first { $0.filename == "2026-01-01-1201-cloud-only.md" }
            Check.equal(cloudy?.availability, "evicted")
            Check.equal(cloudy?.title, "Cloud only", "the title comes from the filename, not a download")

            let body = rig.ok(.searchNotes, ["query": .string("zebra")], as: SearchNotesResult.self)!
            Check.equal(body.results.map(\.note.filename), ["2026-01-01-1200-here.md"])
            Check.equal(body.coverage.bodiesNotSearched, 1)
            Check.equal(body.coverage.bodiesSearched, 1)
            let byTitle = rig.ok(.searchNotes, ["query": .string("cloud only")], as: SearchNotesResult.self)!
            Check.equal(byTitle.results.first?.note.availability, "evicted", "still found by its name")
            Check.equal(cloud.downloadCount, 0, "neither list nor search downloads anything")
        }

        Check.mainTest("read refuses an evicted note unless download is allowed, then downloads that one") {
            let (rig, cloud) = rig()
            rig.seed("2026-01-01-1200-c.md", "# C\n\ntext\n")
            cloud.evict("2026-01-01-1200-c.md")
            let refused = rig.failure(.readNote, ["note_ref": .string(rig.refOf("2026-01-01-1200-c.md"))])
            Check.equal(refused?.code, .noteNotAvailable)
            Check.equal(refused?.details?["availability"], "evicted")
            Check.equal(cloud.downloadCount, 0)

            let read = rig.ok(.readNote, ["note_ref": .string(rig.refOf("2026-01-01-1200-c.md")), "download": .bool(true)], as: ReadNoteResult.self)
            Check.equal(read?.markdown, "# C\n\ntext\n")
            Check.equal(cloud.downloadCount, 1)
        }

        Check.mainTest("a download that runs out of time is DOWNLOAD_TIMEOUT, and the file is untouched") {
            let (rig, cloud) = rig()
            rig.seed("2026-01-01-1200-slow.md", "# Slow\n")
            cloud.evict("2026-01-01-1200-slow.md")
            cloud.failDownload = true
            let failure = rig.failure(.readNote, ["note_ref": .string(rig.refOf("2026-01-01-1200-slow.md")), "download": .bool(true)])
            Check.equal(failure?.code, .downloadTimeout)
            Check.expect(failure?.retryable == true)
            Check.equal(rig.disk("2026-01-01-1200-slow.md"), "# Slow\n")
        }
    }
}
