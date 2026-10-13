import AppKit
import PlumeKit

/// The AppKit half of Git sync: it listens for the Mac waking and tells the scheduler.
///
/// Everything else — when a cycle runs, what the status is — is `GitSyncScheduler`, in PlumeKit,
/// where it is tested. This type is the scheduler's surface to the rest of the app.
@MainActor
final class GitSyncController {

    private let scheduler = GitSyncScheduler()

    /// Held for the life of the process, which is the life of this object.
    private var wakeObserver: NSObjectProtocol?

    var status: GitSyncStatus? { scheduler.status }

    /// Called on the main thread whenever `status` changes.
    var onStatusChange: ((GitSyncStatus?) -> Void)? {
        get { scheduler.onStatusChange }
        set { scheduler.onStatusChange = newValue }
    }

    /// Writes the open note to disk before a cycle reads the folder.
    var beforeCycle: (() -> Void)? {
        get { scheduler.beforeCycle }
        set { scheduler.beforeCycle = newValue }
    }

    init() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduler.systemDidWake() }
        }
    }

    func configure(with settings: Settings) { scheduler.configure(with: settings) }
    func syncNow() { scheduler.syncNow() }
    func vaultDidChange() { scheduler.vaultDidChange() }
    func shutdown() { scheduler.shutdown() }
}
