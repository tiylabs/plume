import Foundation

/// Which dot the menu bar icon wears.
///
/// One at a time, most urgent first: a failure means the sync is not running at all, a conflict means
/// it is paused waiting for you, and an available update is a nicety. Showing the least urgent of them
/// while a worse one stands would be the icon lying by omission.
public enum MenuBarDot: Equatable, Sendable {
    case none
    case update
    case conflict
    case failure

    public static func resolve(sync: GitSyncStatus?, updateAvailable: Bool) -> MenuBarDot {
        switch sync {
        case .failed: return .failure
        case .conflicts: return .conflict
        default: return updateAvailable ? .update : MenuBarDot.none
        }
    }
}
