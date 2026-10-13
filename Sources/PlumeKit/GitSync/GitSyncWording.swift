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
