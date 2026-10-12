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

    /// A development build: its own support folder and its own vault, `~/Documents/Plume-dev`.
    case dev

    /// Kept for older scratch bundles and the packaging guard that rejects development builds.
    public static let infoKey = "PlumeScratchBuild"

    public static let current = resolve(
        bundleIdentifier: Bundle.main.bundleIdentifier,
        scratchFlag: Bundle.main.object(forInfoDictionaryKey: infoKey) as? Bool ?? false
    )

    public static func resolve(bundleIdentifier: String?, scratchFlag: Bool) -> BuildProfile {
        if bundleIdentifier == BuildProfile.dev.bundleIdentifier || scratchFlag { return .dev }
        return .release
    }

    public var bundleIdentifier: String {
        switch self {
        case .release: "com.tiylabs.plume"
        case .dev: "com.tiylabs.plume.dev"
        }
    }

    public var displayName: String {
        switch self {
        case .release: "Plume"
        case .dev: "Plume Dev"
        }
    }

    public var defaultSummonHotkey: Hotkey {
        switch self {
        case .release: .defaultSummon
        case .dev: Hotkey(keyCode: KeyCode.space, modifiers: [.control, .option, .shift])
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
        case .dev: "Plume (Debug)"
        }
    }

    /// Where a fresh install puts the vault. Only ever a *default* — once `settings.json` exists it
    /// carries the answer, and the Storage tab can move it (decision 30).
    ///
    /// The development vault sits beside the release one rather than inside the checkout. It used to
    /// live in `build/`, next to the app, which made `make clean` a hazard: removing build products
    /// meant removing the notes, so the clean rule had to be taught to step around them. Notes are
    /// not a build product, and the answer does not depend on where the checkout is or which
    /// directory LaunchServices started the app in.
    public var defaultVaultPath: String {
        switch self {
        case .release: "~/Documents/Plume"
        case .dev: "~/Documents/Plume-dev"
        }
    }

    /// `defaultVaultPath` as an absolute URL, with `~` taken from `homeDirectory` so a test can point
    /// it at a temporary folder instead of the real home.
    public func defaultVaultURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let path = defaultVaultPath
        guard path.hasPrefix("~/") else { return URL(fileURLWithPath: path) }
        return homeDirectory.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
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
        case .dev: "~/Library/Mobile Documents/com~apple~CloudDocs/Plume-dev"
        }
    }
}
