import Foundation

/// Which copy of Plume this is: the one someone uses, or the one someone is debugging.
///
/// The two used to be the same app as far as macOS was concerned — same bundle identifier, so the
/// same `~/Library/Application Support/Plume`, so **the same `settings.json`, `state.json` and
/// Recently Deleted folder**. That is fine until you want the debug build pointed somewhere safe:
/// `vaultPath` is a setting, and a setting lives in the file both builds read, so pointing the debug
/// build at a scratch vault silently repointed the daily one too. Decision 30's own hazard — a vault
/// re-pointed at an empty folder is indistinguishable from a vault that got destroyed — reached from
/// the one direction nobody was watching, because it is a development path rather than a user one.
///
/// So a scratch build gets its own everything. It is not a mode the app switches into at runtime;
/// its identity is stamped into `Info.plist` by `Scripts/build-app.sh --debug` (or `--dev`) and read
/// once, so inherited environment and stale settings cannot change its channel.
///
/// **This is the second reason to keep the two apart, and the first one is already in the record:**
/// "test against a scratch vault, never the real one — synthetic input into a panel that is showing a
/// real note will edit that note, and did once." A rule that depends on remembering to repoint a
/// shared file is a rule that gets forgotten on the session where it matters.
public enum BuildProfile: Sendable, Equatable {

    /// A release build: `~/Library/Application Support/Plume`, vault defaults to `~/Documents/Plume`.
    case release

    /// A development build: its own support folder and a vault beside the app bundle.
    /// A checkout under Documents may need macOS folder-access consent; custom vaults still work.
    case scratch

    /// Kept for older scratch bundles and the packaging guard that rejects development builds.
    public static let infoKey = "PlumeScratchBuild"

    public static let current = resolve(
        bundleIdentifier: Bundle.main.bundleIdentifier,
        scratchFlag: Bundle.main.object(forInfoDictionaryKey: infoKey) as? Bool ?? false
    )

    public static func resolve(bundleIdentifier: String?, scratchFlag: Bool) -> BuildProfile {
        if bundleIdentifier == BuildProfile.scratch.bundleIdentifier || scratchFlag { return .scratch }
        return .release
    }

    public var bundleIdentifier: String {
        switch self {
        case .release: "com.tiylabs.plume"
        case .scratch: "com.tiylabs.plume.dev"
        }
    }

    public var displayName: String {
        switch self {
        case .release: "Plume"
        case .scratch: "Plume Dev"
        }
    }

    public var defaultSummonHotkey: Hotkey {
        switch self {
        case .release: .defaultSummon
        case .scratch: Hotkey(keyCode: KeyCode.space, modifiers: [.control, .option, .shift])
        }
    }

    /// A dev app never registers a login item or announces releases while being summoned.
    /// Manual update checks remain available for testing the About tab.
    public var allowsSystemIntegration: Bool { self == .release }

    /// The error path must stay in the same profile as the normal Application Support lookup.
    public func fallbackSupportDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    /// The folder under Application Support. Named so the two are told apart in the Finder at a
    /// glance, which matters the first time you go looking for which `state.json` you just broke.
    public var supportDirectoryName: String {
        switch self {
        case .release: "Plume"
        case .scratch: "Plume (Debug)"
        }
    }

    /// Where a fresh install puts the vault. Only ever a *default* — once `settings.json` exists it
    /// carries the answer, and the Storage tab can move it (decision 30).
    public var defaultVaultPath: String { defaultVaultPath(bundleURL: Bundle.main.bundleURL) }

    /// An absolute sibling path does not depend on the working directory LaunchServices chose.
    /// Bare probes have no .app beside which to keep notes, so they retain the old safe fallback.
    public func defaultVaultPath(bundleURL: URL) -> String {
        switch self {
        case .release: return "~/Documents/Plume"
        case .scratch:
            guard bundleURL.pathExtension == "app" else { return "~/Plume-scratch" }
            return bundleURL.deletingLastPathComponent()
                .appendingPathComponent("Plume-scratch", isDirectory: true).standardizedFileURL.path
        }
    }

    /// Where the Sync radio's **iCloud Drive** side puts the vault (decision 133).
    ///
    /// This is the other half of `defaultVaultPath` and it was missing. The radio's *local* side has
    /// read this enum since decision 99; its iCloud side was a literal `…/CloudDocs/Plume` in the
    /// Storage tab, so pressing iCloud Drive in a **scratch** build offered to move scratch notes
    /// into the folder the daily build keeps real ones in — and decision 30's move skips a name that
    /// exists on both sides, so the failure is a silent merge rather than an error.
    ///
    /// Exactly decision 99's hazard, one file over: a development path nobody watches, where the
    /// consequence lands on real notes. The names differ, so the two can share an iCloud account
    /// without ever sharing a folder — which is also the arrangement the two-machine soak already
    /// uses by hand.
    public var iCloudVaultPath: String {
        switch self {
        case .release: "~/Library/Mobile Documents/com~apple~CloudDocs/Plume"
        case .scratch: "~/Library/Mobile Documents/com~apple~CloudDocs/Plume-scratch"
        }
    }
}
