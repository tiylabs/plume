import Foundation

/// The user's Git-sync choices: whether it is on, and where it goes.
///
/// Stored in `settings.json` like everything else the user chooses. There is deliberately no field for
/// a password or a token — authentication is the system git's, and whatever it is configured with
/// (ssh keys, the macOS keychain) is what runs. See `GitRunner`.
public struct GitSyncSettings: Codable, Equatable, Sendable {

    public var enabled: Bool

    /// The remote's address, exactly as `git remote add origin <url>` takes it.
    public var remoteURL: String

    /// Empty means the remote's own default branch.
    public var branch: String

    public init(enabled: Bool = false, remoteURL: String = "", branch: String = "") {
        self.enabled = enabled
        self.remoteURL = remoteURL
        self.branch = branch
    }

    /// As forgiving as `Settings` itself: this file is meant to be hand-edited, and one bad field
    /// should cost that field, not the launch.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        remoteURL = (try c.decodeIfPresent(String.self, forKey: .remoteURL) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        branch = (try c.decodeIfPresent(String.self, forKey: .branch) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Enabled with an address. A hand edit that flips `enabled` on with no URL is not a sync.
    public var isActive: Bool { enabled && !remoteURL.isEmpty }
}
