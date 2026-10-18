import Foundation

/// The writes-per-minute ceiling, as a sliding window.
///
/// Over the limit is refused with a `retry_after`, never queued: a queued write lands later than the
/// agent believes it did, and a runaway loop would just fill the queue. A retry of a request that
/// already has an operation does not count — it creates nothing.
public final class AgentRateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [Date] = []
    private let limit: Int
    private let window: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        limit: Int = AgentLimits.writesPerMinute,
        window: TimeInterval = 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.limit = limit
        self.window = window
        self.now = now
    }

    /// Takes a slot, or throws `RATE_LIMITED` with the whole seconds until one frees up.
    public func take() throws {
        lock.lock()
        defer { lock.unlock() }
        let current = now()
        stamps.removeAll { current.timeIntervalSince($0) >= window }
        guard stamps.count < limit else {
            let wait = max(1, Int((window - current.timeIntervalSince(stamps[0])).rounded(.up)))
            throw AgentFailure(
                .rateLimited,
                "more than \(limit) writes in a minute; wait \(wait) s and retry with the same request_id",
                details: ["retry_after": String(wait)]
            )
        }
        stamps.append(current)
    }
}
