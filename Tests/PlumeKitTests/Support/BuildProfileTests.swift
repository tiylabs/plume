import Foundation
import PlumeKit

func runBuildProfileTests() {
    Check.suite("Build profile") {

        Check.test("release identity and defaults remain unchanged") {
            let release = BuildProfile.release
            Check.equal(release.bundleIdentifier, "com.tiylabs.plume")
            Check.equal(release.displayName, "Plume")
            Check.equal(release.supportDirectoryName, "Plume")
            Check.equal(release.defaultVaultPath, "~/Documents/Plume")
            Check.equal(release.defaultSummonHotkey, Hotkey.defaultSummon)
            Check.expect(release.allowsSystemIntegration)
            Check.equal(Settings().checkForUpdates, true)
            Check.equal(Settings().launchAtLogin, false)
        }

        Check.test("dev identity and hotkey are independent of release") {
            let dev = BuildProfile.dev
            Check.notEqual(dev.bundleIdentifier, BuildProfile.release.bundleIdentifier)
            Check.equal(dev.displayName, "Plume Dev")
            Check.equal(dev.defaultSummonHotkey.settingsString, "control+option+shift+space")
            Check.notEqual(dev.defaultSummonHotkey, Hotkey.defaultSummon)
            Check.expect(!dev.allowsSystemIntegration)
        }

        Check.test("bundle identity or legacy scratch flag selects development") {
            Check.equal(BuildProfile.resolve(bundleIdentifier: "com.tiylabs.plume.dev", scratchFlag: false), .dev)
            Check.equal(BuildProfile.resolve(bundleIdentifier: "com.tiylabs.plume", scratchFlag: true), .dev)
            Check.equal(BuildProfile.resolve(bundleIdentifier: "com.tiylabs.plume", scratchFlag: false), .release)
            Check.equal(BuildProfile.resolve(bundleIdentifier: nil, scratchFlag: false), .release)
        }

        Check.test("fallback paths preserve the same isolation as normal paths") {
            let home = URL(fileURLWithPath: "/test-home")
            Check.equal(BuildProfile.release.fallbackSupportDirectory(homeDirectory: home).path,
                        "/test-home/Library/Application Support/Plume")
            Check.equal(BuildProfile.dev.fallbackSupportDirectory(homeDirectory: home).path,
                        "/test-home/Library/Application Support/Plume (Debug)")
        }

        Check.test("development settings migration cannot change release settings") {
            var settings = Settings(vaultPath: "~/CustomNotes", launchAtLogin: true, checkForUpdates: true)
            let original = settings
            settings.isolateDevelopmentSettings(profile: .release)
            Check.equal(settings, original)
            settings.isolateDevelopmentSettings(profile: .dev)
            Check.equal(settings.vaultPath, original.vaultPath)
            Check.equal(settings.summonHotkey, BuildProfile.dev.defaultSummonHotkey)
            Check.expect(!settings.launchAtLogin)
            Check.expect(!settings.checkForUpdates)
            let migrated = settings
            settings.isolateDevelopmentSettings(profile: .dev)
            Check.equal(settings, migrated)
        }

        Check.test("development migration preserves custom hotkeys") {
            guard let custom = try? Hotkey.parse("command+shift+p") else { return }
            var settings = Settings(summonHotkey: custom)
            settings.isolateDevelopmentSettings(profile: .dev)
            Check.equal(settings.summonHotkey, custom)
        }

        // The point of these is not that the strings are right — they are two lines of code. It is
        // that the two profiles can never *collide*, because the whole reason this type exists is
        // that they used to share one settings.json and a debug session repointed the daily build's
        // vault with it.
        Check.test("the two profiles share nothing") {
            Check.expect(
                BuildProfile.release.supportDirectoryName
                    != BuildProfile.dev.supportDirectoryName,
                "both profiles resolved to the same Application Support folder"
            )
            Check.expect(
                BuildProfile.release.defaultVaultPath != BuildProfile.dev.defaultVaultPath,
                "both profiles resolved to the same default vault"
            )
            // Added by decision 133, and the reason is this test rather than the bug: it asserted
            // "the two profiles share nothing" over the two paths that existed when it was written,
            // so a third path could be added without it — and was. Every location the profile knows
            // about has to differ, which is what the loop below enforces going forward.
            Check.expect(
                BuildProfile.release.iCloudVaultPath != BuildProfile.dev.iCloudVaultPath,
                "both profiles resolved to the same iCloud Drive vault"
            )
        }

        // Written as a sweep rather than as three named assertions on purpose. A path added to
        // `BuildProfile` and not to this list is the shape of the fault decision 133 fixed, so the
        // list is the thing to keep honest — and a `switch` over both cases is what makes forgetting
        // one a compile error rather than a silent pass.
        Check.test("every location a profile names differs between the two") {
            let release: [(String, String)] = [
                ("support directory", BuildProfile.release.supportDirectoryName),
                ("default vault", BuildProfile.release.defaultVaultPath),
                ("iCloud vault", BuildProfile.release.iCloudVaultPath),
            ]
            let scratch: [(String, String)] = [
                ("support directory", BuildProfile.dev.supportDirectoryName),
                ("default vault", BuildProfile.dev.defaultVaultPath),
                ("iCloud vault", BuildProfile.dev.iCloudVaultPath),
            ]
            for (r, s) in zip(release, scratch) {
                Check.expect(r.1 != s.1, "\(r.0) is the same folder in both builds: \(r.1)")
            }
        }

        // The Sync radio's iCloud side was a literal in the Storage tab, so pressing iCloud Drive in
        // a scratch build offered to move scratch notes into the folder the daily build keeps real
        // ones in. Decision 30's move *skips a name that exists on both sides*, so the failure mode
        // was a silent merge, not an error.
        Check.test("a scratch build's iCloud vault is not the release build's") {
            Check.expect(
                !BuildProfile.dev.iCloudVaultPath.hasSuffix("/Plume"),
                "got \(BuildProfile.dev.iCloudVaultPath), which is the daily vault"
            )
            Check.expect(
                BuildProfile.release.iCloudVaultPath.hasSuffix("/Plume"),
                "the release build must keep the folder people already have their notes in"
            )
            // Both still inside the same iCloud container, so the two Macs can share one account.
            for path in [BuildProfile.release.iCloudVaultPath, BuildProfile.dev.iCloudVaultPath] {
                Check.expect(
                    path.contains("Library/Mobile Documents/com~apple~CloudDocs/"),
                    "not in iCloud Drive at all: \(path)"
                )
            }
        }

        // The development vault used to be `build/Plume-scratch`, beside the app, which made `make
        // clean` a hazard to the notes. It is now a fixed folder beside the release one, and it does
        // not depend on where the app bundle happens to be.
        Check.test("development notes default to ~/Documents/Plume-dev wherever the app is") {
            Check.equal(BuildProfile.dev.defaultVaultPath, "~/Documents/Plume-dev")
            Check.equal(BuildProfile.release.defaultVaultPath, "~/Documents/Plume")
            let home = URL(fileURLWithPath: "/Users/someone")
            Check.equal(BuildProfile.dev.defaultVaultURL(homeDirectory: home).path,
                        "/Users/someone/Documents/Plume-dev")
            Check.equal(BuildProfile.release.defaultVaultURL(homeDirectory: home).path,
                        "/Users/someone/Documents/Plume")
            Check.expect(
                !BuildProfile.dev.defaultVaultPath.contains("build"),
                "the dev vault must not live in a build directory that `make clean` removes"
            )
        }

        /// A scratch app, a home directory and the two places a dev build used to keep its notes.
        func withLegacyLayout(_ body: (_ root: URL, _ home: URL, _ app: URL) throws -> Void) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                try body(root, root.appendingPathComponent("home"), root.appendingPathComponent("checkout/build/Plume Dev.app"))
            } catch { Check.expect(false, "fixture failed: \(error)") }
        }
        func makeNote(in folder: URL, _ text: String) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appendingPathComponent("note.md"))
        }
        func read(_ folder: URL) -> String? {
            try? String(contentsOf: folder.appendingPathComponent("note.md"), encoding: .utf8)
        }

        Check.test("notes in ~/Plume-scratch are copied to ~/Documents/Plume-dev and the source is retained") {
            withLegacyLayout { _, home, app in
                let legacy = home.appendingPathComponent("Plume-scratch")
                try makeNote(in: legacy, "# Old scratch note")
                var settings = Settings(vaultPath: "~/Plume-scratch")
                try settings.migrateDevelopmentVault(profile: .dev, bundleURL: app, homeDirectory: home)
                let destination = home.appendingPathComponent("Documents/Plume-dev")
                Check.equal(settings.vaultPath, destination.path)
                Check.equal(read(destination), "# Old scratch note")
                Check.equal(read(legacy), "# Old scratch note", "the source is a backup and stays")
                // A repeat neither overwrites the new note nor recopies a modified legacy source.
                try Data("# Changed legacy".utf8).write(to: legacy.appendingPathComponent("note.md"))
                try settings.migrateDevelopmentVault(profile: .dev, bundleURL: app, homeDirectory: home)
                Check.equal(read(destination), "# Old scratch note")
            }
        }

        Check.test("notes in build/Plume-scratch beside the app are migrated too") {
            withLegacyLayout { root, home, app in
                let legacy = root.appendingPathComponent("checkout/build/Plume-scratch")
                try makeNote(in: legacy, "# Beside the app")
                var settings = Settings(vaultPath: legacy.path)
                try settings.migrateDevelopmentVault(profile: .dev, bundleURL: app, homeDirectory: home)
                let destination = home.appendingPathComponent("Documents/Plume-dev")
                Check.equal(settings.vaultPath, destination.path)
                Check.equal(read(destination), "# Beside the app")
                Check.equal(read(legacy), "# Beside the app", "and the source stays")
            }
        }

        Check.test("a different checkout's build/Plume-scratch is not this app's old default") {
            withLegacyLayout { root, home, app in
                let other = root.appendingPathComponent("elsewhere/build/Plume-scratch")
                try makeNote(in: other, "# Somebody else's")
                var settings = Settings(vaultPath: other.path)
                try settings.migrateDevelopmentVault(profile: .dev, bundleURL: app, homeDirectory: home)
                Check.equal(settings.vaultPath, other.path)
                Check.expect(!FileManager.default.fileExists(
                    atPath: home.appendingPathComponent("Documents/Plume-dev").path))
            }
        }

        Check.test("migration never merges into an existing destination, and leaves custom paths and release alone") {
            withLegacyLayout { _, home, app in
                let legacy = home.appendingPathComponent("Plume-scratch")
                let destination = home.appendingPathComponent("Documents/Plume-dev")
                try makeNote(in: legacy, "# Legacy")
                try makeNote(in: destination, "# Existing destination")
                var settings = Settings(vaultPath: legacy.path)
                try settings.migrateDevelopmentVault(profile: .dev, bundleURL: app, homeDirectory: home)
                Check.equal(settings.vaultPath, legacy.path, "the configured vault stays where it was")
                Check.equal(read(destination), "# Existing destination", "and the destination is untouched")
                settings.vaultPath = "~/CustomNotes"
                try settings.migrateDevelopmentVault(profile: .dev, bundleURL: app, homeDirectory: home)
                Check.equal(settings.vaultPath, "~/CustomNotes")
                settings.vaultPath = "~/Plume-scratch"
                try settings.migrateDevelopmentVault(profile: .release, bundleURL: app, homeDirectory: home)
                Check.equal(settings.vaultPath, "~/Plume-scratch")
            }
        }

        Check.test("missing or failed legacy migration leaves settings untouched") {
            withLegacyLayout { _, home, app in
                var settings = Settings(vaultPath: "~/Plume-scratch")
                try settings.migrateDevelopmentVault(profile: .dev, bundleURL: app, homeDirectory: home)
                Check.equal(settings.vaultPath, "~/Plume-scratch", "no source folder: nothing to move")
                let legacy = home.appendingPathComponent("Plume-scratch")
                try makeNote(in: legacy, "# Retained")
                // A file where the destination's parent folder should be makes the copy impossible.
                try Data("blocks parent creation".utf8).write(to: home.appendingPathComponent("Documents"))
                do {
                    try settings.migrateDevelopmentVault(profile: .dev, bundleURL: app, homeDirectory: home)
                    Check.expect(false, "migration should fail when the parent is a file")
                } catch {
                    Check.equal(settings.vaultPath, "~/Plume-scratch")
                    Check.equal(read(legacy), "# Retained")
                }
            }
        }

        // A test binary, a probe and anything else without the Info.plist key is a release build.
        // This is what keeps the rest of the suite free of any opinion about this machine — see the
        // vault-path assertions in StateTests.
        Check.test("an unstamped bundle is a release build") {
            Check.equal(BuildProfile.current, .release)
            Check.equal(Settings.defaultVaultPath, BuildProfile.release.defaultVaultPath)
        }
    }
}
