import Foundation

/// The assignment the window must obey. Plume's saved preference is kept separately so a Dock
/// assignment can temporarily take precedence without destroying the user's application setting.
public struct SpaceAssignmentPolicy: Equatable, Sendable {
    public let mode: Settings.SpaceAssignment
    public let desktopUUID: String?
    public let isSystemManaged: Bool

    public var showsOnEverySpace: Bool { mode == .everySpace }

    public static func resolve(
        settings: Settings,
        dock: DockSpaceAssignment,
        previous: Self? = nil
    ) -> Self {
        switch dock {
        case .oneSpace(let uuid):
            return Self(mode: .oneSpace, desktopUUID: uuid, isSystemManaged: true)
        case .everySpace:
            return Self(mode: .everySpace, desktopUUID: nil, isSystemManaged: true)
        case .unknown:
            // A transient read failure must not turn canJoinAllSpaces back on over a known binding.
            if let previous, previous.isSystemManaged { return previous }
            fallthrough
        case .unassigned:
            let mode = settings.spaceAssignment == .oneSpace && settings.assignedSpace == nil
                ? Settings.SpaceAssignment.unassigned : settings.spaceAssignment
            return Self(
                mode: mode,
                desktopUUID: mode == .oneSpace ? settings.assignedSpace : nil,
                isSystemManaged: false
            )
        }
    }
}
