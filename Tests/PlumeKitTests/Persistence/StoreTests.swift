import Foundation
import PlumeKit

private func temporaryDirectory() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("store-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func read<T: Decodable>(_ type: T.Type, at url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(T.self, from: data)
}

func runStoreTests() {
    Check.mainSuite("StateStore") {

        @MainActor func makeStore(_ dir: URL, _ clock: ManualScheduler) -> (StateStore, URL) {
            let url = dir.appendingPathComponent("state.json")
            return (StateStore(store: JSONFileStore<AppState>(url: url), scheduler: clock), url)
        }

        Check.mainTest("a first launch starts from defaults and writes nothing") {
            let dir = temporaryDirectory()
            let (store, url) = makeStore(dir, ManualScheduler())
            Check.equal(store.loadOutcome, .fresh)
            Check.equal(store.value, AppState())
            Check.expect(!FileManager.default.fileExists(atPath: url.path), "loading must not create the file")
        }

        Check.mainTest("updates inside the coalescing window are one write, after the window") {
            let dir = temporaryDirectory()
            let clock = ManualScheduler()
            let (store, url) = makeStore(dir, clock)

            store.update { $0.vaultEverCreated = true }
            clock.advance(by: StateStore.coalesceInterval - 0.5)
            store.update { $0.availableUpdate = "1.2.3" }
            clock.advance(by: StateStore.coalesceInterval - 0.5)
            Check.expect(!FileManager.default.fileExists(atPath: url.path),
                         "each update restarts the window, so nothing is due yet")

            clock.advance(by: 0.6)
            let onDisk = read(AppState.self, at: url)
            Check.equal(onDisk?.vaultEverCreated, true)
            Check.equal(onDisk?.availableUpdate, "1.2.3", "the later update is in the same write")
            Check.equal(clock.pendingCount, 0)
        }

        Check.mainTest("save() writes at once and cancels the pending write") {
            let dir = temporaryDirectory()
            let clock = ManualScheduler()
            let (store, url) = makeStore(dir, clock)

            store.update { $0.vaultEverCreated = true }
            Check.equal(clock.pendingCount, 1)
            store.save()
            Check.equal(read(AppState.self, at: url)?.vaultEverCreated, true)
            Check.equal(clock.pendingCount, 0, "the timer must not write the same state again")
        }

        Check.mainTest("the file is overwritten by a later save, and read back by the next launch") {
            let dir = temporaryDirectory()
            let clock = ManualScheduler()
            let (store, url) = makeStore(dir, clock)
            store.update { $0.vaultEverCreated = true }
            store.save()

            let (again, _) = makeStore(dir, ManualScheduler())
            Check.equal(again.loadOutcome, .loaded)
            Check.equal(again.value.vaultEverCreated, true)
            Check.expect(FileManager.default.fileExists(atPath: url.path))
        }

        Check.mainTest("a damaged file is moved aside and the store starts from defaults") {
            let dir = temporaryDirectory()
            let url = dir.appendingPathComponent("state.json")
            try? "{ not json".write(to: url, atomically: true, encoding: .utf8)
            let store = StateStore(store: JSONFileStore<AppState>(url: url), scheduler: ManualScheduler())
            if case .recovered = store.loadOutcome {} else {
                Check.expect(false, "expected .recovered, got \(store.loadOutcome)")
            }
            Check.equal(store.value, AppState())
        }
    }

    Check.mainSuite("SettingsStore") {

        @MainActor func makeStore(
            _ dir: URL, profile: BuildProfile = .release, seed: Settings? = nil
        ) -> (SettingsStore, URL) {
            let url = dir.appendingPathComponent("settings.json")
            let file = JSONFileStore<Settings>(url: url)
            if let seed { try? file.save(seed) }
            let store = SettingsStore(
                store: file, profile: profile,
                bundleURL: dir.appendingPathComponent("not-an-app"), homeDirectory: dir
            )
            return (store, url)
        }

        Check.mainTest("an update that changes nothing neither writes nor calls back") {
            let dir = temporaryDirectory()
            let (store, url) = makeStore(dir)
            var calls = 0
            store.onChange = { _ in calls += 1 }
            let before = try? Data(contentsOf: url)

            store.update { $0.textSize = $0.textSize }
            Check.equal(calls, 0)
            Check.equal(try? Data(contentsOf: url), before, "the file must be untouched")
        }

        Check.mainTest("an update that changes something writes first, then calls back with the new value") {
            let dir = temporaryDirectory()
            let (store, url) = makeStore(dir)
            var seenOnDisk: Double?
            store.onChange = { value in
                seenOnDisk = read(Settings.self, at: url)?.textSize
                Check.equal(value.textSize, 20)
            }
            store.update { $0.textSize = 20 }
            Check.equal(seenOnDisk, 20, "the callback ran after the write")
        }

        Check.mainTest("our own write is not mistaken for a hand edit") {
            let dir = temporaryDirectory()
            let (store, _) = makeStore(dir)
            var calls = 0
            store.onChange = { _ in calls += 1 }
            store.update { $0.textSize = 21 }
            Check.equal(calls, 1)
            store.reloadFromDisk()
            Check.equal(calls, 1, "re-reading what we just wrote is not news")
        }

        Check.mainTest("a hand edit is picked up once, and re-reading it again is quiet") {
            let dir = temporaryDirectory()
            let (store, url) = makeStore(dir)
            var calls = 0
            store.onChange = { _ in calls += 1 }

            var edited = store.value
            edited.textSize = 24
            try? JSONFileStore<Settings>(url: url).save(edited)
            store.reloadFromDisk()
            Check.equal(calls, 1)
            Check.equal(store.value.textSize, 24)
            store.reloadFromDisk()
            Check.equal(calls, 1)
        }

        Check.mainTest("an unreadable file on reload leaves the live settings alone") {
            let dir = temporaryDirectory()
            let (store, url) = makeStore(dir)
            store.update { $0.textSize = 22 }
            var calls = 0
            store.onChange = { _ in calls += 1 }
            try? "{ nope".write(to: url, atomically: true, encoding: .utf8)
            store.reloadFromDisk()
            Check.equal(store.value.textSize, 22)
            Check.equal(calls, 0)
        }

        Check.mainTest("a development build forces its isolation back after any change") {
            let dir = temporaryDirectory()
            let (store, url) = makeStore(dir, profile: .dev)
            store.update { $0.launchAtLogin = true; $0.checkForUpdates = true }
            Check.expect(!store.value.launchAtLogin, "a dev build never registers a login item")
            Check.expect(!store.value.checkForUpdates)
            Check.equal(read(Settings.self, at: url)?.launchAtLogin, false)
        }

        Check.mainTest("a release build leaves the same change alone") {
            let dir = temporaryDirectory()
            let (store, _) = makeStore(dir, profile: .release)
            store.update { $0.launchAtLogin = true }
            Check.expect(store.value.launchAtLogin)
        }

        Check.mainTest("loading a dev file with the release hotkey migrates and persists it") {
            let dir = temporaryDirectory()
            var seed = Settings()
            seed.summonHotkey = Hotkey.defaultSummon
            seed.launchAtLogin = true
            let (store, url) = makeStore(dir, profile: .dev, seed: seed)
            Check.equal(store.value.summonHotkey, BuildProfile.dev.defaultSummonHotkey)
            Check.equal(read(Settings.self, at: url)?.summonHotkey, BuildProfile.dev.defaultSummonHotkey,
                        "the migration is written back, not only held in memory")
        }

        Check.mainTest("loading a release file never rewrites it") {
            let dir = temporaryDirectory()
            var seed = Settings()
            seed.textSize = 17
            let (_, url) = makeStore(dir, profile: .release, seed: seed)
            let before = try? Data(contentsOf: url)
            _ = makeStore(dir, profile: .release)
            Check.equal(try? Data(contentsOf: url), before)
        }
    }
}
