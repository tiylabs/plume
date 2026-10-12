import Foundation

/// How a sync status reads, in one place for the menu and the Storage tab.
///
/// In PlumeKit rather than beside the controller so the wording — which is most of what a person
/// sees of the feature — can be checked without a window server.
public enum GitSyncWording {

    /// How recent a sync has to be to read as "just now".
    public static let justNowWindow: TimeInterval = 45

    /// "3 minutes ago", in the language the app is set to.
    public static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = L10n.locale
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        // Our own words for the first moments: the system's "now" is a bare 现在 in Chinese, which
        // reads as a clock and not as "a moment ago".
        if abs(now.timeIntervalSince(date)) < justNowWindow { return L10n.t("storage.git.justNow") }
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// The Storage tab's one-line value.
    public static func headline(_ status: GitSyncStatus, now: Date = Date()) -> String {
        switch status {
        case .idle(let last?): return L10n.t("storage.git.status.idle", ["time": relative(last, now: now)])
        case .idle(nil): return L10n.t("storage.git.status.never")
        case .syncing: return L10n.t("storage.git.status.syncing")
        case .conflicts(let files):
            return L10n.plural("menubar.sync.conflicts", count: files.count)
        case .failed: return L10n.t("storage.git.status.failedShort")
        }
    }

    /// The sentence under it, when there is more to say.
    public static func detail(_ status: GitSyncStatus) -> String {
        switch status {
        case .conflicts(let files): return L10n.plural("storage.git.status.conflicts", count: files.count)
        case .failed(let failure): return failure.message
        default: return ""
        }
    }
}

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
