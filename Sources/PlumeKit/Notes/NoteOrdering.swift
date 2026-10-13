import Foundation

/// How the ⌘P switcher orders and labels notes.
///
/// The design's hard problem is the switcher at 200 notes, and its answer is landmarks: pins float
/// to the top, everything else falls into recency bands you can scroll past without reading. Below a
/// handful of notes the bands are noise, so they disappear entirely.
public enum NoteOrdering {

    /// Group headers start appearing at this many notes. Under it, the switcher is one flat
    /// recency-ordered list — headers over a four-row list are chrome pretending to be structure.
    public static let groupingThreshold = 8

    // MARK: - What "recent" means

    /// The one timestamp a switcher row is sorted by, banded by, and labelled with.
    ///
    /// Decision 104. The mode picks *which* clock, and then that clock does all three jobs — which
    /// is decision 45's rule ("one value for sorting and display") holding per mode rather than
    /// being given up: sorting by one value and printing another is what produces a row sitting
    /// under "Today" with "Jul 30" beside it.
    ///
    /// `.created` falls back to the mtime for a file the user named by hand, because such a file has
    /// no creation time Plume can read without trusting `.creationDate` through a sync round trip.
    public static func activity(
        _ order: Settings.NoteOrder,
        filename: String,
        modified: Date,
        lastOpened: Date?,
        timeZone: TimeZone = .current
    ) -> Date {
        switch order {
        case .modified:
            return modified
        case .opened:
            guard let lastOpened else { return modified }
            return max(modified, lastOpened)
        case .created:
            return NoteFilename.creationDate(from: filename, timeZone: timeZone) ?? modified
        }
    }

    // MARK: - Bands

    public enum Band: Equatable, Hashable, Sendable {
        case pinned
        case today
        case yesterday
        case thisWeek
        /// A calendar month in the current year: "July".
        case month(year: Int, month: Int)
        /// Anything older, labelled with the year: "July 2025".
        case olderMonth(year: Int, month: Int)

        /// Sort key. Pinned first, then most recent band first.
        public var rank: Int {
            switch self {
            case .pinned: return 0
            case .today: return 1
            case .yesterday: return 2
            case .thisWeek: return 3
            case .month(let y, let m): return 4 + (9999 - y) * 12 + (12 - m)
            case .olderMonth(let y, let m): return 4 + (9999 - y) * 12 + (12 - m)
            }
        }
    }

    /// The band a note belongs to.
    public static func band(
        modified: Date,
        isPinned: Bool,
        now: Date,
        calendar: Calendar = .current
    ) -> Band {
        if isPinned { return .pinned }

        if calendar.isDate(modified, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(modified, inSameDayAs: yesterday) {
            return .yesterday
        }

        // "This week" is the six days before yesterday — a rolling window, not a calendar week, so
        // the band does not empty itself every Monday morning.
        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)),
           modified >= weekAgo {
            return .thisWeek
        }

        let c = calendar.dateComponents([.year, .month], from: modified)
        let nowYear = calendar.component(.year, from: now)
        let y = c.year ?? nowYear
        let m = c.month ?? 1
        return y == nowYear ? .month(year: y, month: m) : .olderMonth(year: y, month: m)
    }

    /// - Parameter locale: decides both the wording (`Today`/`今天`) and the date formatting, so a
    ///   caller that passes one gets one language throughout. The app passes `L10n.locale`.
    public static func label(
        for band: Band,
        calendar: Calendar = .current,
        locale: Locale = L10n.locale
    ) -> String {
        let language = L10n.language(for: locale)
        switch band {
        case .pinned: return L10n.t("band.pinned", language: language)
        case .today: return L10n.t("band.today", language: language)
        case .yesterday: return L10n.t("band.yesterday", language: language)
        case .thisWeek: return L10n.t("band.thisWeek", language: language)
        case .month(_, let m):
            return monthName(m, calendar: calendar, locale: locale)
        case .olderMonth(let y, let m):
            // A template rather than `"\(month) \(y)"`: English says "July 2025", Chinese says
            // "2025年7月", and the order is the language's to decide.
            return L10n.t(
                "band.olderMonth",
                ["month": monthName(m, calendar: calendar, locale: locale), "year": String(y)],
                language: language
            )
        }
    }

    private static func monthName(_ month: Int, calendar: Calendar, locale: Locale) -> String {
        var cal = calendar
        cal.locale = locale
        let names = cal.monthSymbols
        guard month >= 1, month <= names.count else { return "" }
        return names[month - 1]
    }

    // MARK: - Relative time

    /// The compact timestamp on a switcher row: `now`, `42m`, `2h`, `Wed`, `Jul 30`, `May 12, 2025`.
    ///
    /// Each band trades precision for width as the note gets older, because the question the column
    /// answers changes: for today's notes it's "how long ago", for this week's it's "which day", and
    /// beyond that it's just a date.
    public static func relativeTime(
        _ date: Date,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = L10n.locale
    ) -> String {
        let seconds = now.timeIntervalSince(date)

        let language = L10n.language(for: locale)
        // Clock skew, or a file whose mtime a sync daemon set slightly in the future.
        if seconds < 60 { return L10n.t("time.now", language: language) }

        if calendar.isDate(date, inSameDayAs: now) {
            let minutes = Int(seconds / 60)
            if minutes < 60 {
                return L10n.t("time.minutes", ["count": String(minutes)], language: language)
            }
            return L10n.t("time.hours", ["count": String(minutes / 60)], language: language)
        }

        if let weekAgo = calendar.date(byAdding: .day, value: -7, to: calendar.startOfDay(for: now)),
           date >= weekAgo {
            var cal = calendar
            cal.locale = locale
            let weekday = cal.component(.weekday, from: date)
            let symbols = cal.shortWeekdaySymbols
            if weekday >= 1, weekday <= symbols.count { return symbols[weekday - 1] }
        }

        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        f.setLocalizedDateFormatFromTemplate(sameYear ? "MMM d" : "MMM d y")
        return f.string(from: date)
    }
}
