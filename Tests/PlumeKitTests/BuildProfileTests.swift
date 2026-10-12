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
            let dev = BuildProfile.scratch
            Check.notEqual(dev.bundleIdentifier, BuildProfile.release.bundleIdentifier)
            Check.equal(dev.displayName, "Plume Dev")
            Check.equal(dev.defaultSummonHotkey.settingsString, "control+option+shift+space")
            Check.notEqual(dev.defaultSummonHotkey, Hotkey.defaultSummon)
            Check.expect(!dev.allowsSystemIntegration)
        }

        Check.test("bundle identity or legacy scratch flag selects development") {
            Check.equal(BuildProfile.resolve(bundleIdentifier: "com.tiylabs.plume.dev", scratchFlag: false), .scratch)
            Check.equal(BuildProfile.resolve(bundleIdentifier: "com.tiylabs.plume", scratchFlag: true), .scratch)
            Check.equal(BuildProfile.resolve(bundleIdentifier: "com.tiylabs.plume", scratchFlag: false), .release)
            Check.equal(BuildProfile.resolve(bundleIdentifier: nil, scratchFlag: false), .release)
        }

        Check.test("fallback paths preserve the same isolation as normal paths") {
            let home = URL(fileURLWithPath: "/test-home")
            Check.equal(BuildProfile.release.fallbackSupportDirectory(homeDirectory: home).path,
                        "/test-home/Library/Application Support/Plume")
            Check.equal(BuildProfile.scratch.fallbackSupportDirectory(homeDirectory: home).path,
                        "/test-home/Library/Application Support/Plume (Debug)")
        }

        Check.test("development settings migration cannot change release settings") {
            var settings = Settings(vaultPath: "~/CustomNotes", launchAtLogin: true, checkForUpdates: true)
            let original = settings
            settings.isolateDevelopmentSettings(profile: .release)
            Check.equal(settings, original)
            settings.isolateDevelopmentSettings(profile: .scratch)
            Check.equal(settings.vaultPath, original.vaultPath)
            Check.equal(settings.summonHotkey, BuildProfile.scratch.defaultSummonHotkey)
            Check.expect(!settings.launchAtLogin)
            Check.expect(!settings.checkForUpdates)
            let migrated = settings
            settings.isolateDevelopmentSettings(profile: .scratch)
            Check.equal(settings, migrated)
        }

        Check.test("development migration preserves custom hotkeys") {
            guard let custom = try? Hotkey.parse("command+shift+p") else { return }
            var settings = Settings(summonHotkey: custom)
            settings.isolateDevelopmentSettings(profile: .scratch)
            Check.equal(settings.summonHotkey, custom)
        }

        // The point of these is not that the strings are right — they are two lines of code. It is
        // that the two profiles can never *collide*, because the whole reason this type exists is
        // that they used to share one settings.json and a debug session repointed the daily build's
        // vault with it.
        Check.test("the two profiles share nothing") {
            Check.expect(
                BuildProfile.release.supportDirectoryName
                    != BuildProfile.scratch.supportDirectoryName,
                "both profiles resolved to the same Application Support folder"
            )
            Check.expect(
                BuildProfile.release.defaultVaultPath != BuildProfile.scratch.defaultVaultPath,
                "both profiles resolved to the same default vault"
            )
            // Added by decision 133, and the reason is this test rather than the bug: it asserted
            // "the two profiles share nothing" over the two paths that existed when it was written,
            // so a third path could be added without it — and was. Every location the profile knows
            // about has to differ, which is what the loop below enforces going forward.
            Check.expect(
                BuildProfile.release.iCloudVaultPath != BuildProfile.scratch.iCloudVaultPath,
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
                ("support directory", BuildProfile.scratch.supportDirectoryName),
                ("default vault", BuildProfile.scratch.defaultVaultPath),
                ("iCloud vault", BuildProfile.scratch.iCloudVaultPath),
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
                !BuildProfile.scratch.iCloudVaultPath.hasSuffix("/Plume"),
                "got \(BuildProfile.scratch.iCloudVaultPath), which is the daily vault"
            )
            Check.expect(
                BuildProfile.release.iCloudVaultPath.hasSuffix("/Plume"),
                "the release build must keep the folder people already have their notes in"
            )
            // Both still inside the same iCloud container, so the two Macs can share one account.
            for path in [BuildProfile.release.iCloudVaultPath, BuildProfile.scratch.iCloudVaultPath] {
                Check.expect(
                    path.contains("Library/Mobile Documents/com~apple~CloudDocs/"),
                    "not in iCloud Drive at all: \(path)"
                )
            }
        }

        Check.test("development notes are an absolute sibling of the app") {
            let app = URL(fileURLWithPath: "/checkout/build/Plume Dev.app")
            Check.equal(BuildProfile.scratch.defaultVaultPath(bundleURL: app), "/checkout/build/Plume-scratch")
            Check.equal(BuildProfile.release.defaultVaultPath(bundleURL: app), "~/Documents/Plume")
            let other = URL(fileURLWithPath: "/other checkout/build/Plume Dev.app")
            Check.equal(BuildProfile.scratch.defaultVaultPath(bundleURL: other),
                        "/other checkout/build/Plume-scratch")
            Check.equal(BuildProfile.scratch.defaultVaultPath(bundleURL: URL(fileURLWithPath: "/probe")),
                        "~/Plume-scratch")
        }

        Check.test("legacy development notes are copied intact and the source is retained") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                let home = root.appendingPathComponent("home")
                let legacy = home.appendingPathComponent("Plume-scratch")
                try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
                try Data("# Old scratch note".utf8).write(to: legacy.appendingPathComponent("note.md"))
                let app = root.appendingPathComponent("build/Plume Dev.app")
                var settings = Settings(vaultPath: "~/Plume-scratch")
                try settings.migrateDevelopmentVault(profile: .scratch, bundleURL: app, homeDirectory: home)
                Check.equal(settings.vaultPath, root.appendingPathComponent("build/Plume-scratch").path)
                Check.equal(try String(contentsOf: settings.vaultURL.appendingPathComponent("note.md"), encoding: .utf8),
                            "# Old scratch note")
                Check.expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("note.md").path))
                // A repeat neither overwrites the new note nor recopies a modified legacy source.
                try Data("# Changed legacy".utf8).write(to: legacy.appendingPathComponent("note.md"))
                try settings.migrateDevelopmentVault(profile: .scratch, bundleURL: app, homeDirectory: home)
                Check.equal(try String(contentsOf: settings.vaultURL.appendingPathComponent("note.md"), encoding: .utf8),
                            "# Old scratch note")
            } catch { Check.expect(false, "migration failed: \(error)") }
        }

        Check.test("migration preserves existing destinations, custom paths and release settings") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                let home = root.appendingPathComponent("home")
                let legacy = home.appendingPathComponent("Plume-scratch")
                let destination = root.appendingPathComponent("build/Plume-scratch")
                try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try Data("# Existing destination".utf8).write(to: destination.appendingPathComponent("note.md"))
                let app = root.appendingPathComponent("build/Plume Dev.app")
                var settings = Settings(vaultPath: legacy.path)
                try settings.migrateDevelopmentVault(profile: .scratch, bundleURL: app, homeDirectory: home)
                Check.equal(settings.vaultPath, legacy.path)
                Check.equal(try String(contentsOf: destination.appendingPathComponent("note.md"), encoding: .utf8),
                            "# Existing destination")
                settings.vaultPath = "~/CustomNotes"
                try settings.migrateDevelopmentVault(profile: .scratch, bundleURL: app, homeDirectory: home)
                Check.equal(settings.vaultPath, "~/CustomNotes")
                settings.vaultPath = "~/Plume-scratch"
                try settings.migrateDevelopmentVault(profile: .release, bundleURL: app, homeDirectory: home)
                Check.equal(settings.vaultPath, "~/Plume-scratch")
            } catch { Check.expect(false, "migration checks failed: \(error)") }
        }

        Check.test("missing or failed legacy migration leaves settings untouched") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                let home = root.appendingPathComponent("home")
                let app = root.appendingPathComponent("build/Plume Dev.app")
                var settings = Settings(vaultPath: "~/Plume-scratch")
                try settings.migrateDevelopmentVault(profile: .scratch, bundleURL: app, homeDirectory: home)
                Check.equal(settings.vaultPath, "~/Plume-scratch")
                let legacy = home.appendingPathComponent("Plume-scratch")
                try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
                try Data("# Retained".utf8).write(to: legacy.appendingPathComponent("note.md"))
                try Data("blocks parent creation".utf8).write(to: root.appendingPathComponent("build"))
                do {
                    try settings.migrateDevelopmentVault(profile: .scratch, bundleURL: app, homeDirectory: home)
                    Check.expect(false, "migration should fail when the parent is a file")
                } catch {
                    Check.equal(settings.vaultPath, "~/Plume-scratch")
                    Check.expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("note.md").path))
                }
            } catch { Check.expect(false, "fixture setup failed: \(error)") }
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
