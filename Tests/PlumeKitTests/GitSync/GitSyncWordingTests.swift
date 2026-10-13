import Foundation
import PlumeKit

/// How a sync status reads — the headline, the detail line, the "just now" window — in every shipped
/// language, and that no failure or verification step ever shows a bare catalog key.
func runGitSyncWordingTests() {
    guard let directory = L10n.bundledDirectory() else {
        Check.suite("Git sync · wording") {
            Check.test("the Locales folder is found") { Check.expect(false, "set PLUME_LOCALES") }
        }
        return
    }
    L10n.configure(directory: directory)
    defer { L10n.setLanguage(L10n.fallbackLanguage) }

    let now = Date(timeIntervalSince1970: 1_800_000_000)

    Check.suite("Git sync · wording") {

        Check.test("a sync in the last moments reads as just now, in each language") {
            L10n.setLanguage("en")
            Check.equal(GitSyncWording.relative(now.addingTimeInterval(-10), now: now), "just now")
            L10n.setLanguage("zh-Hans")
            Check.equal(GitSyncWording.relative(now.addingTimeInterval(-10), now: now), "刚刚")
            Check.equal(GitSyncWording.relative(now, now: now), "刚刚")
        }

        Check.test("the just-now window ends at forty-five seconds") {
            L10n.setLanguage("zh-Hans")
            Check.equal(GitSyncWording.relative(now.addingTimeInterval(-44), now: now), "刚刚")
            Check.notEqual(GitSyncWording.relative(now.addingTimeInterval(-46), now: now), "刚刚")
        }

        Check.test("older syncs say how long ago") {
            L10n.setLanguage("en")
            Check.expect(GitSyncWording.relative(now.addingTimeInterval(-300), now: now).contains("5"))
            L10n.setLanguage("zh-Hans")
            let text = GitSyncWording.relative(now.addingTimeInterval(-300), now: now)
            Check.expect(text.contains("5") && text.contains("分钟"), text)
        }

        Check.test("the headline for every status") {
            L10n.setLanguage("en")
            Check.equal(GitSyncWording.headline(.idle(lastSync: nil)), "Not synced yet")
            Check.equal(GitSyncWording.headline(.idle(lastSync: now), now: now), "Last synced just now")
            Check.equal(GitSyncWording.headline(.syncing), "Syncing…")
            Check.equal(GitSyncWording.headline(.conflicts(["a.md"])), "Sync conflict in 1 note")
            Check.equal(GitSyncWording.headline(.conflicts(["a.md", "b.md"])), "Sync conflicts in 2 notes")
            Check.equal(GitSyncWording.headline(.failed(.network)), "Sync failed")

            L10n.setLanguage("zh-Hans")
            Check.equal(GitSyncWording.headline(.idle(lastSync: nil)), "尚未同步")
            Check.equal(GitSyncWording.headline(.idle(lastSync: now), now: now), "上次同步 刚刚")
            Check.equal(GitSyncWording.headline(.conflicts(["a.md", "b.md", "c.md"])), "3 篇笔记存在同步冲突")
        }

        Check.test("the detail line exists only when there is more to say") {
            L10n.setLanguage("en")
            Check.equal(GitSyncWording.detail(.idle(lastSync: now)), "")
            Check.equal(GitSyncWording.detail(.syncing), "")
            Check.expect(GitSyncWording.detail(.conflicts(["a.md"])).contains("<<<<<<<"))
            Check.equal(GitSyncWording.detail(.failed(.network)), GitSyncFailure.network.message)
        }

        Check.test("every failure has a sentence in every language, and none is a bare key") {
            let all: [GitSyncFailure] = [
                .gitMissing, .authenticationFailed, .noWriteAccess, .network, .repositoryNotFound,
                .branchMissing, .repositoryState(""), .repositoryState("locked"), .other(""), .other("boom"),
            ]
            var english: [String] = []
            L10n.setLanguage("en")
            for failure in all {
                Check.expect(!failure.message.isEmpty && !failure.message.hasPrefix("sync."), "\(failure) → \(failure.message)")
                english.append(failure.message)
            }
            L10n.setLanguage("zh-Hans")
            for (failure, before) in zip(all, english) {
                Check.expect(!failure.message.isEmpty && !failure.message.hasPrefix("sync."), "\(failure) → \(failure.message)")
                Check.notEqual(failure.message, before, "\(failure) is not translated")
            }
            L10n.setLanguage("en")
            Check.expect(GitSyncFailure.repositoryState("locked").message.contains("locked"))
            Check.expect(GitSyncFailure.other("boom").message.contains("boom"))
        }

        Check.test("every verification step has a label in every language") {
            for language in ["en", "zh-Hans"] {
                L10n.setLanguage(language)
                for step in GitSyncValidation.Step.allCases {
                    Check.expect(!step.label.hasPrefix("sync."), "\(language) \(step.rawValue)")
                }
            }
        }
    }
}
