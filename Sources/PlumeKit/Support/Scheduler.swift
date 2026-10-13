import Foundation

/// Something that can be called off before it fires.
public protocol Cancellable {
    func cancel()
}

/// "Run this later, on the main actor." The one way PlumeKit code asks for a delay.
///
/// Debouncing, coalescing and periodic work all reduce to a delayed closure. Taking that from a
/// protocol rather than from `DispatchQueue.main.asyncAfter` directly is what lets a test move time
/// by hand instead of sleeping: the app passes `MainQueueScheduler`, the suite passes a scheduler it
/// advances itself.
@MainActor
public protocol Scheduling {
    /// Calls `work` once, `delay` seconds from now, unless the returned token is cancelled first.
    @discardableResult
    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> any Cancellable
}

/// The real thing: the main dispatch queue.
public struct MainQueueScheduler: Scheduling {

    public init() {}

    @discardableResult
    public func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> any Cancellable {
        let item = DispatchWorkItem { MainActor.assumeIsolated(work) }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return WorkItemToken(item)
    }
}

private struct WorkItemToken: Cancellable {
    let item: DispatchWorkItem
    init(_ item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}
