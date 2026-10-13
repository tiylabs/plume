import AppKit
import OSLog
import PlumeKit

/// Reads system assignments and reports changes; the controller owns the resulting window policy.
@MainActor
final class DockSpaceAssignmentMonitor {
    private(set) var assignment: DockSpaceAssignment = .unknown(.notReadYet)
    var onChange: ((DockSpaceAssignment) -> Void)?

    private let reader = DockSpaceAssignmentReader(bundleIdentifier: Bundle.main.bundleIdentifier)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.tiylabs.plume", category: "DockSpaces")
    private var pollingTask: Task<Void, Never>?
    private var readInFlight = false

    func start() {
        guard pollingTask == nil else { return }
        refresh()
        // There is no public notification for Dock assignment edits. A fresh snapshot every two
        // seconds also catches changes persisted after an activation/Space-change notification.
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                self?.refresh()
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh), name: NSApplication.didBecomeActiveNotification, object: nil
        )
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didWakeNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(refresh), name: name, object: nil
            )
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        // Observers attach in `start`, which `PanelController` may call again after `stop`, so
        // removal cannot wait for `deinit` — this is the lifecycle point paired with attachment.
        // swiftlint:disable:next notification_center_detachment
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    deinit {
        pollingTask?.cancel()
        // The rule wants removal here; `stop` already does it when the panel is torn down.
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc func refresh() {
        guard !readInFlight else { return }
        readInFlight = true
        let reader = reader
        Task { [weak self] in
            let observed = await Task.detached(priority: .utility) { reader.read() }.value
            guard let self else { return }
            self.readInFlight = false
            guard observed != self.assignment else { return }
            self.assignment = observed
            self.logger.info("Dock assignment: \(observed.diagnosticValue, privacy: .public)")
            self.onChange?(observed)
        }
    }
}
