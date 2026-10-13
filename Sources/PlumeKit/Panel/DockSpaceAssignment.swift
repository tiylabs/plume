import Foundation

/// A read-only observation of the Dock's Assign To setting, independent of Plume's preferences.
/// The preference format is undocumented. Only recognised values are evidence of an assignment;
/// missing or malformed data must never be interpreted as the user choosing None.
public enum DockSpaceAssignment: Equatable, Sendable {
    case unassigned
    case everySpace
    case oneSpace(uuid: String)
    case unknown(UnknownReason)

    public enum UnknownReason: String, Sendable {
        case notReadYet
        case missingBundleIdentifier
        case preferencesUnreadable
        case invalidPropertyList
        case bindingsUnavailable
        case unrecognisedBinding
    }

    /// `app-bindings` is the table observed on macOS. An absent entry in a valid table means None;
    /// an absent table does not establish that the system still uses this representation.
    public static func parse(propertyList: Any, bundleIdentifier: String?) -> Self {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return .unknown(.missingBundleIdentifier)
        }
        guard let preferences = propertyList as? [String: Any] else {
            return .unknown(.invalidPropertyList)
        }
        guard let bindings = preferences["app-bindings"] as? [String: Any] else {
            return .unknown(.bindingsUnavailable)
        }
        guard let binding = bindings[bundleIdentifier] else { return .unassigned }
        guard let value = binding as? String else { return .unknown(.unrecognisedBinding) }
        if value == "AllSpaces" { return .everySpace }
        guard let uuid = UUID(uuidString: value) else { return .unknown(.unrecognisedBinding) }
        return .oneSpace(uuid: uuid.uuidString)
    }

    /// A compact diagnostic value. Kept separate from translated UI text.
    public var diagnosticValue: String {
        switch self {
        case .unassigned: "unassigned"
        case .everySpace: "everySpace"
        case .oneSpace(let uuid): "oneSpace:\(uuid)"
        case .unknown(let reason): "unknown:\(reason.rawValue)"
        }
    }
}

/// Reads a fresh file snapshot rather than UserDefaults' cross-process cache. It never writes,
/// synchronises a preference domain, or restarts Dock. Call off the main thread in the application.
/// Dock/cfprefsd may delay persisting changes: this is an observation of persisted preferences,
/// not a guarantee that WindowServer has applied the same value at this instant.
public struct DockSpaceAssignmentReader: Sendable {
    public let bundleIdentifier: String?
    public let preferencesURL: URL

    public init(
        bundleIdentifier: String?,
        preferencesURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.spaces.plist")
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.preferencesURL = preferencesURL
    }

    public func read() -> DockSpaceAssignment {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else {
            return .unknown(.missingBundleIdentifier)
        }
        guard let data = try? Data(contentsOf: preferencesURL) else {
            return .unknown(.preferencesUnreadable)
        }
        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) else {
            return .unknown(.invalidPropertyList)
        }
        return DockSpaceAssignment.parse(propertyList: propertyList, bundleIdentifier: bundleIdentifier)
    }
}
