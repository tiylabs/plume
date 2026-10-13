import Foundation

/// The notes visited in one panel, oldest first, with a position — ⌘[ and ⌘].
///
/// In memory rather than in `state.json`: this describes one sitting with the app, and a Back that
/// reaches across a relaunch into notes you have forgotten visiting is a worse answer than one that
/// starts fresh. It is also the reason there is no schema change here.
///
/// A plain value so that "Back never lands on a note that is gone" and "a new visit from the middle
/// discards what was ahead" are properties a test can state, not behaviour of a window.
public struct NavigationHistory: Equatable, Sendable {

    /// Long enough that Back never runs out in a real session, short enough to stay a rounding error
    /// in a process that runs for weeks.
    public static let limit = 50

    public private(set) var entries: [String] = []
    /// The entry on screen, or -1 before the first visit.
    public private(set) var index = -1

    public init() {}

    /// Records a note that really opened.
    public mutating func recordVisit(_ filename: String) {
        // Opening something new from the middle of the history discards what was ahead, exactly as a
        // browser does: those entries describe a future that has now not happened.
        if index >= 0, index < entries.count - 1 {
            entries.removeSubrange((index + 1)...)
        }
        guard entries.last != filename else { return }
        entries.append(filename)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        index = entries.count - 1
    }

    /// Steps back and returns the note to open, or nil at the start.
    public mutating func back() -> String? {
        guard index > 0 else { return nil }
        index -= 1
        return entries[index]
    }

    /// Steps forward and returns the note to open, or nil at the end.
    public mutating func forward() -> String? {
        guard index >= 0, index < entries.count - 1 else { return nil }
        index += 1
        return entries[index]
    }

    /// Points every entry that named `old` at `new`. Back and Forward hold filenames, so an
    /// un-rewritten entry is a ⌘[ onto a file that no longer exists — which opening would then treat
    /// as a missing note and drop from state.
    public mutating func rename(_ old: String, to new: String) {
        for position in entries.indices where entries[position] == old { entries[position] = new }
    }
}
