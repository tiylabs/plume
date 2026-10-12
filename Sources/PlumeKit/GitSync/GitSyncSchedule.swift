import Foundation

/// When a timed cycle may run.
///
/// A cycle commits whatever is in the folder, so one that fires mid-sentence would commit half of
/// it. Notes are written 0.5 s after typing stops, so a vault that changed in the last few seconds is
/// a vault somebody is still using: wait, and ask again. But not for ever — a folder that changes
/// constantly would otherwise never sync.
public enum GitSyncSchedule {

    /// "Every 5 minutes" is the product's number.
    public static let interval: TimeInterval = 5 * 60

    /// How long the vault must have been still before a timed cycle commits.
    public static let quietPeriod: TimeInterval = 5

    /// How many times in a row a cycle may be put off before it runs regardless.
    public static let maxPostponements = 6

    public enum Decision: Equatable, Sendable {
        case run
        case postpone(after: TimeInterval)
    }

    public static func decide(sinceLastActivity: TimeInterval, postponements: Int) -> Decision {
        if sinceLastActivity < quietPeriod, postponements < maxPostponements {
            return .postpone(after: quietPeriod)
        }
        return .run
    }
}
