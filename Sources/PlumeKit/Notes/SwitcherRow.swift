import Foundation

/// A switcher row, in the exact shape the web layer's `NoteSummary` expects.
///
/// `Codable` because it crosses the bridge as JSON. Ordering, banding and time formatting are all
/// decided here, in Swift, where they are tested — the web layer draws what it is given (decision 4).
public struct SwitcherRow: Codable, Equatable, Sendable {
    public struct Match: Codable, Equatable, Sendable {
        public var pre: String
        public var hit: String
        public var post: String
    }

    public var filename: String
    public var title: String
    public var time: String
    public var preview: String
    public var band: String?
    public var pinned: Bool?
    public var current: Bool?
    public var match: Match?

    /// Public because the Recently Deleted list is built in the app target rather than here — it is
    /// the same row drawn by the same switcher, just sourced from the holding folder (decision 20).
    /// The four optionals default to nil so that caller states its four fields and no more.
    public init(
        filename: String,
        title: String,
        time: String,
        preview: String,
        band: String? = nil,
        pinned: Bool? = nil,
        current: Bool? = nil,
        match: Match? = nil
    ) {
        self.filename = filename
        self.title = title
        self.time = time
        self.preview = preview
        self.band = band
        self.pinned = pinned
        self.current = current
        self.match = match
    }
}
