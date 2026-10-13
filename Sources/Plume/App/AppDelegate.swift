import AppKit

/// The system's name for what is running, and nothing more: it forwards each callback to
/// `AppCoordinator`, which holds everything with a process lifetime.
///
/// The coordinator is created here and not at file scope because an `NSApplicationDelegate` is
/// `@MainActor` and the callbacks arrive on the main thread; `NSApplication.delegate` is weak, so
/// `main.swift` keeps this object alive for the process.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.willTerminate()
    }

    /// Plume has no Dock icon by default, but if `showDockIcon` is on, clicking it should summon
    /// rather than do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        coordinator.reopened()
        return true
    }
}
