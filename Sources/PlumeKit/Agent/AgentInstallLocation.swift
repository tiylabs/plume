import Darwin
import Foundation

/// Which app a helper belongs to, decided from where the helper really is on disk.
///
/// The rule: resolve the executable's real path (every symlink followed); it must sit at
/// `<Something>.app/Contents/MacOS/plume-agent`; that app's own `Info.plist` names the profile. A
/// helper anywhere else — a symlink into a bundle is fine, but a copy in `.build/` or `~/bin` is not —
/// refuses to run.
///
/// Not `BuildProfile.current`, on purpose. That reads `Bundle.main`, which for a binary run through
/// a symlink or from outside a bundle has no bundle identifier — and `BuildProfile.resolve` answers
/// `.release` for that. A development helper would then connect to the person's real notes. Not an
/// environment variable either: an agent's configuration could then point any helper at any
/// profile, and the whole point of the Dev profile is that it cannot reach the daily one.
public struct AgentInstallLocation: Sendable, Equatable {
    public var appBundle: URL
    public var profile: BuildProfile
    public var appVersion: String

    public var instance: String { AgentInstance.identifier(bundleURL: appBundle) }
    public var helperURL: URL {
        appBundle.appendingPathComponent("Contents/MacOS").appendingPathComponent(AgentAPI.helperExecutableName)
    }

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case notInAppBundle(String)
        case unreadableInfoPlist(String)
        case unknownBundle(String)

        public var description: String {
            switch self {
            case .notInAppBundle(let path):
                "plume-agent must run from inside Plume.app (Contents/MacOS); it is at \(path). Use the path shown in Plume's settings."
            case .unreadableInfoPlist(let path):
                "cannot read the Info.plist of the app containing plume-agent: \(path)"
            case .unknownBundle(let identifier):
                "plume-agent is inside an app that is not Plume (\(identifier))"
            }
        }
    }

    public init(appBundle: URL, profile: BuildProfile, appVersion: String) {
        self.appBundle = appBundle
        self.profile = profile
        self.appVersion = appVersion
    }

    /// The location of the helper at `executablePath`, symlinks resolved.
    public static func resolve(executablePath: String) throws -> AgentInstallLocation {
        let real = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().standardizedFileURL
        let macOS = real.deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app"
        else { throw Problem.notInAppBundle(real.path) }

        let plistURL = contents.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { throw Problem.unreadableInfoPlist(plistURL.path) }

        let identifier = plist["CFBundleIdentifier"] as? String ?? ""
        let scratch = plist[BuildProfile.infoKey] as? Bool ?? false
        let profile: BuildProfile
        switch identifier {
        case BuildProfile.release.bundleIdentifier where !scratch: profile = .release
        case BuildProfile.release.bundleIdentifier, BuildProfile.dev.bundleIdentifier: profile = .dev
        default: throw Problem.unknownBundle(identifier.isEmpty ? "no bundle identifier" : identifier)
        }
        let version = plist["CFBundleShortVersionString"] as? String ?? "0"
        return AgentInstallLocation(appBundle: bundle, profile: profile, appVersion: version)
    }

    /// This process's own executable, as the kernel knows it — not `argv[0]`, which is whatever the
    /// caller typed and may be a relative path or a symlink name.
    public static func currentExecutablePath() -> String {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return CommandLine.arguments[0] }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    // MARK: - Whether a path will still be there tomorrow

    /// Why a configuration pointing at this app would stop working, or nil if it will not.
    ///
    /// Gatekeeper's App Translocation runs a quarantined app from a random read-only path that
    /// changes on every launch; a disk image is a volume that goes away when ejected. A configuration
    /// written with either path works today and fails tomorrow with nothing to explain why, so
    /// Settings offers no configuration until the app has been moved somewhere permanent.
    public enum Impermanence: Error, Equatable, Sendable {
        case translocated
        case readOnlyVolume
    }

    public static func impermanence(of bundle: URL) -> Impermanence? {
        if bundle.path.contains("/AppTranslocation/") { return .translocated }
        if let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]), values.volumeIsReadOnly == true {
            return .readOnlyVolume
        }
        return nil
    }
}
