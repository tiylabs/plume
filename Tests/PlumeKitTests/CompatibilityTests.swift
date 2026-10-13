import Foundation
import PlumeKit

/// What is already on users' disks. These files are written by one build and read by the next — or
/// by the previous one, after a downgrade — so the names in them are frozen: the keys of
/// `settings.json` and `state.json`, including the ones that look like leftovers (`plumes`,
/// `pinPlume`). A refactor that renames a Swift property must keep the JSON byte-identical, and
/// these tests are what says so. See Design/Notes/architecture-refactor-plan.md, section 2.
///
/// Fixtures live in `Fixtures/` beside this file and are found through `#filePath`, because the
/// suite is an executable target rather than one with SwiftPM resources.
///
/// `PLUME_UPDATE_FIXTURES=1` rewrites `settings-default.json` from the current encoder. That is for
/// a deliberate, documented format change only — the diff of the fixture is the review.
private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Fixtures", isDirectory: true)

private func fixture(_ name: String) -> Data {
    guard let data = try? Data(contentsOf: fixtures.appendingPathComponent(name)) else {
        fatalError("missing fixture \(name)")
    }
    return data
}

/// The encoder `JSONFileStore` uses, so the bytes compared are the bytes that reach the disk.
private func encoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    e.dateEncodingStrategy = .iso8601
    return e
}

private func decoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}

private func jsonObject(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

func runCompatibilityTests() {
    Check.suite("On-disk compatibility") {

        Check.test("a default Settings encodes to exactly the shipped file") {
            // The test executable is not an .app, so the build profile resolves to release: this is
            // the file a fresh release install writes.
            let data = try! encoder().encode(Settings())
            let golden = fixtures.appendingPathComponent("settings-default.json")
            if ProcessInfo.processInfo.environment["PLUME_UPDATE_FIXTURES"] == "1" {
                try! data.write(to: golden)
            }
            let expected = String(decoding: fixture("settings-default.json"), as: UTF8.self)
            Check.equal(String(decoding: data, as: UTF8.self), expected,
                        "settings key set or default changed — if deliberate, see the header of this file")
        }

        Check.test("every settings key survives a round trip unchanged") {
            let original = jsonObject(fixture("settings-default.json"))
            let again = jsonObject(try! encoder().encode(try! decoder().decode(Settings.self, from: fixture("settings-default.json"))))
            Check.equal(Set(again.keys), Set(original.keys))
        }

        Check.test("a hand-edited settings file keeps its values and the in-panel shortcut key pinPlume") {
            let s = try! decoder().decode(Settings.self, from: fixture("settings-handedited.json"))
            Check.equal(s.shortcuts["pinPlume"], "Shift-Mod-k", "rebinding is stored under pinPlume")
            Check.equal(s.shortcuts["someFutureAction"], "Mod-j", "an unknown action key is kept on load")
            // The action is looked up by that exact key, so the rename of the *concept* must not
            // reach the persisted name.
            Check.expect(Settings.standardShortcuts["pinPlume"] != nil, "the shipped table still has pinPlume")
            Check.expect(Settings.shortcutActions.contains { $0.key == "pinPlume" }, "the Shortcuts tab still lists pinPlume")
            // And a value the file did not mention comes back as the shipped default.
            Check.equal(s.shortcuts["navigateBack"], Settings.standardShortcuts["navigateBack"])
        }

        Check.test("state.json written by an older build decodes: panels are stored under plumes") {
            let state = try! decoder().decode(AppState.self, from: fixture("state-legacy.json"))
            Check.equal(state.panels.count, 1, "the panel list is read from the `plumes` key")
            Check.equal(state.panels.first?.noteFilename, "2026-08-11-1453-first-few-words.md")
            Check.equal(state.panels.first?.manualHeight, 420)
            Check.equal(state.panels.first?.frames["primary"]?.width, 460)
            Check.equal(state.notes.count, 2)
            Check.equal(state.note("2026-08-11-1453-first-few-words.md").isPinned, true)
            Check.equal(state.note("2026-08-11-1453-first-few-words.md").caretOffset, 42)
            Check.equal(state.vaultEverCreated, true)
            Check.equal(state.availableUpdate, "0.9.0")
        }

        Check.test("state.json is written back with the same keys, so a downgrade can still read it") {
            let state = try! decoder().decode(AppState.self, from: fixture("state-legacy.json"))
            let out = jsonObject(try! encoder().encode(state))
            let original = jsonObject(fixture("state-legacy.json"))
            Check.equal(Set(out.keys), Set(original.keys), "top-level keys")
            Check.expect(out["plumes"] != nil, "still written as `plumes`")
            Check.expect(out["panels"] == nil, "never written as `panels`")

            let panelOut = (out["plumes"] as? [[String: Any]])?.first ?? [:]
            let panelOriginal = (original["plumes"] as? [[String: Any]])?.first ?? [:]
            Check.equal(Set(panelOut.keys), Set(panelOriginal.keys), "per-panel keys")

            let noteOut = ((out["notes"] as? [String: Any])?["2026-08-11-1453-first-few-words.md"] as? [String: Any]) ?? [:]
            let noteOriginal = ((original["notes"] as? [String: Any])?["2026-08-11-1453-first-few-words.md"] as? [String: Any]) ?? [:]
            Check.equal(Set(noteOut.keys), Set(noteOriginal.keys), "per-note keys")
        }
    }
}
