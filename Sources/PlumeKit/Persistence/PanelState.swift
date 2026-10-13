import CoreGraphics
import Foundation

public struct PanelState: Codable, Equatable, Sendable, Identifiable {

    public var id: UUID

    /// The note this panel is showing. `nil` for a panel that has not been pointed at one yet.
    public var noteFilename: String?

    /// Whether the format bar is open. Per panel, per the design's note that the state persists.
    public var showsFormatBar: Bool

    /// Remembered geometry, keyed by display. "Stay put" means a panel returns to where the user left
    /// it *on that screen* — plugging in a monitor must not shuffle the panels on the built-in one.
    ///
    /// The key comes from `PanelGeometry.displayKey`, and it is the display's **persistent UUID**.
    /// It was the `CGDirectDisplayID` until v0.6.5, which macOS re-issues on every power cycle, so
    /// this map grew a fresh orphan every time a monitor was switched off and the panel came back at
    /// its first-launch size.
    public var frames: [String: StoredFrame]

    /// The size the panel was last left at, on whatever display.
    ///
    /// Seeds a display the panel has never been used on, so a new monitor inherits a size the user
    /// chose instead of the first-launch one. Kept beside `frames` rather than derived from it: a
    /// dictionary has no recency, and picking an arbitrary entry would make the size depend on hash
    /// order.
    public var lastSize: StoredSize?

    /// Whether the panel's height still follows its content (rule 2).
    ///
    /// **A drag turns this off**, which is the whole mechanism — see decision 40. The previous
    /// answer treated a dragged height as a *floor* that auto-sizing could grow past but never
    /// shrink below, and that cannot work: on any note longer than the panel, the content height is
    /// always above the floor, so the floor never applies and the panel springs straight back to the
    /// note's height. Dragging a long note's panel smaller did nothing at all.
    public var autoSizing: Bool

    /// The height to hold while `autoSizing` is off — the one the user dragged to.
    ///
    /// `nil` while auto-sizing is on, because then the content decides. Overlays are the exception
    /// in both modes: the switcher and ⌘K may always force the panel taller, since a panel clipped by
    /// the window it lives in is not a size anyone chose.
    ///
    /// **This is a whole-panel value and `frames` is per display, so it is the seed and not the
    /// answer** — read the held height through `heldHeight(onDisplay:)`, which prefers the display's
    /// own remembered frame. Taking this value directly is what made a panel dragged tall on one
    /// monitor come back tall on the other while correctly keeping that monitor's width
    /// (decision 130).
    public var manualHeight: Double?

    public init(
        id: UUID = UUID(),
        noteFilename: String? = nil,
        showsFormatBar: Bool = false,
        frames: [String: StoredFrame] = [:],
        lastSize: StoredSize? = nil,
        autoSizing: Bool = true,
        manualHeight: Double? = nil
    ) {
        self.id = id
        self.noteFilename = noteFilename
        self.showsFormatBar = showsFormatBar
        self.frames = frames
        self.lastSize = lastSize
        self.autoSizing = autoSizing
        self.manualHeight = manualHeight
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        noteFilename = try c.decodeIfPresent(String.self, forKey: .noteFilename)
        showsFormatBar = try c.decodeIfPresent(Bool.self, forKey: .showsFormatBar) ?? false
        // Frames filed under the old display-ID key can never match again, and there can be dozens
        // of them — 56 for two monitors on the Mac that found this. Dropped on read rather than
        // migrated: an ID cannot be translated into the UUID it briefly stood for.
        let stored = try c.decodeIfPresent([String: StoredFrame].self, forKey: .frames) ?? [:]
        frames = stored.filter { !PanelGeometry.isLegacyDisplayKey($0.key) }
        lastSize = try c.decodeIfPresent(StoredSize.self, forKey: .lastSize)
        autoSizing = try c.decodeIfPresent(Bool.self, forKey: .autoSizing) ?? true
        manualHeight = try c.decodeIfPresent(Double.self, forKey: .manualHeight)
        // A state.json written before decision 40 carries a `manualHeight` that meant "floor", with
        // no `autoSizing` beside it. Read as the new pair that is "auto-sizing on, held at the old
        // floor", which is nonsense — so the height is dropped rather than silently pinning the panel.
        if autoSizing { manualHeight = nil }
    }
}

extension PanelState {

    /// The height to hold on a given display while auto-sizing is off.
    ///
    /// **Per display, because a size is per display.** `frames` has always been keyed by display and
    /// carries a full rect, so the height the user dragged to on *this* monitor is already recorded;
    /// `manualHeight` is one number for the whole panel and only seeds a display the panel has not
    /// been sized on yet. Reading `manualHeight` directly meant the panel restored the right width
    /// for the display and then immediately overwrote the height with the other display's — visible
    /// only once frames reliably survived a display change, which is to say only after decision 128.
    ///
    /// `nil` while auto-sizing is on: then the note decides and there is nothing to hold.
    public func heldHeight(onDisplay key: String) -> Double? {
        guard !autoSizing else { return nil }
        return frames[key]?.height ?? manualHeight
    }
}

/// A panel size, stored the same way and for the same reason as `StoredFrame`.
public struct StoredSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public init(_ size: CGSize) {
        self.init(width: Double(size.width), height: Double(size.height))
    }

    public var size: CGSize { CGSize(width: width, height: height) }
}

/// A window frame in AppKit screen coordinates, stored as named fields rather than the array
/// `CGRect`'s synthesised conformance produces — state.json is a file a curious user will open, and
/// `[820, 512, 692, 400]` tells them nothing.
public struct StoredFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }

    public var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
