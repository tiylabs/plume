import Foundation
import PlumeKit

/// A clock the test turns by hand. Nothing scheduled on it ever fires until `advance(by:)` says
/// enough time has passed, so a two-second debounce is tested in microseconds and deterministically.
@MainActor
final class ManualScheduler: Scheduling {

    private final class Entry: Cancellable {
        let due: TimeInterval
        let order: Int
        var work: (@MainActor () -> Void)?
        init(due: TimeInterval, order: Int, work: @escaping @MainActor () -> Void) {
            self.due = due
            self.order = order
            self.work = work
        }
        func cancel() { work = nil }
    }

    private var entries: [Entry] = []
    private var counter = 0

    /// Seconds advanced so far.
    private(set) var now: TimeInterval = 0

    /// Scheduled and neither fired nor cancelled.
    var pendingCount: Int { entries.filter { $0.work != nil }.count }

    @discardableResult
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> any Cancellable {
        counter += 1
        let entry = Entry(due: now + delay, order: counter, work: work)
        entries.append(entry)
        return entry
    }

    /// Moves time forward, running everything that falls due, in order — including work scheduled by
    /// work that ran, if it also falls inside the window.
    func advance(by seconds: TimeInterval) {
        let target = now + seconds
        while let next = entries
            .filter({ $0.work != nil && $0.due <= target })
            .min(by: { ($0.due, $0.order) < ($1.due, $1.order) }) {
            now = max(now, next.due)
            let work = next.work
            next.work = nil
            work?()
        }
        now = target
        entries.removeAll { $0.work == nil }
    }
}
