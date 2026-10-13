import CoreGraphics
import Foundation

/// Everything Plume remembers about *how you were using* your notes, as opposed to what is in them.
///
/// This is the whole of decision 11: caret offsets, recency, pins, window geometry and the last-used
/// note live in `~/Library/Application Support/Plume/state.json`, outside the vault and never synced.
/// None of it may leak into a note file. Frontmatter would break the byte-for-byte bar, would sync,
/// and would make the vault Plume's private format rather than a folder of markdown the user owns.
///
/// The accepted consequence is that pins are per-machine — a pin says what you are working on *at
/// this desk*, which is not a property of the note.
public struct AppState: Codable, Equatable, Sendable {

    /// Bumped when a field changes meaning rather than merely being added. Additive changes keep the
    /// version: every property below has a default, so an older file decodes cleanly.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int

    /// Per-note state, keyed by the note's frozen filename — which never changes, which is exactly
    /// what makes it usable as a key (decision 2).
    public var notes: [String: NoteState]

    /// Open panels. A list, not a single optional, because a note is an independently ownable panel
    /// (decision 9). v0.1 shows one; nothing here assumes that.
    public var panels: [PanelState]

    /// Set the first time Plume creates a vault, and never cleared.
    ///
    /// This one flag is the whole of decision 13's hard case. A vault that has never existed and a
    /// vault that has been deleted are the same absence on disk; without a record kept *outside* the
    /// vault, "create it silently" and "ask" cannot be told apart — and picking wrong means a user
    /// whose notes are gone sees a cheerful empty panel instead of a question.
    public var vaultEverCreated: Bool

    /// When the release check last ran, so it can run about once a day rather than once a summon.
    ///
    /// State, not a preference: nobody sets this and nobody should have to look at it. The setting
    /// that governs whether it happens at all is `Settings.checkForUpdates`.
    public var lastUpdateCheck: Date?

    /// The newer version the last check found, or nil when it found none.
    ///
    /// **Persisted because the menu bar item is the part that waits**, and waiting has to survive a
    /// relaunch — it is the answer to "I saw a toast last week, where do I get it". Held in memory
    /// only, it was gone on the next launch and did not come back until the daily check came round
    /// again, which is a durable notice that is durable for less time than a session.
    ///
    /// Still derived, never dismissed: every check's answer goes through `ReleaseCheck.remembered`,
    /// and `ReleaseCheck.pending` re-compares it against the running version on the way out of the
    /// file, so upgrading clears it at once rather than at the next check.
    ///
    /// There used to be an `announcedUpdate` beside it, so the toast fired once per version. The
    /// toast now repeats daily until the upgrade, so it is gone; a state.json from an older build
    /// still carries the key, and decoding ignores it.
    public var availableUpdate: String?

    /// The JSON keys. `panels` is stored as `plumes`, the name it had when `state.json` first shipped.
    ///
    /// The key does not follow the Swift property on purpose: the file is read by this build after an
    /// upgrade and by an older one after a downgrade, and a renamed key would silently read as "no
    /// panels", dropping the remembered frames and note. `CompatibilityTests` holds this to the byte.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, notes, vaultEverCreated, lastUpdateCheck, availableUpdate
        case panels = "plumes"
    }

    public init(
        schemaVersion: Int = AppState.currentSchemaVersion,
        notes: [String: NoteState] = [:],
        panels: [PanelState] = [],
        vaultEverCreated: Bool = false,
        lastUpdateCheck: Date? = nil,
        availableUpdate: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.notes = notes
        self.panels = panels
        self.vaultEverCreated = vaultEverCreated
        self.lastUpdateCheck = lastUpdateCheck
        self.availableUpdate = availableUpdate
    }

    // Hand-written so a state.json missing any key still decodes — a file written by an older build
    // must never cost the user their pins.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        notes = try c.decodeIfPresent([String: NoteState].self, forKey: .notes) ?? [:]
        panels = try c.decodeIfPresent([PanelState].self, forKey: .panels) ?? []

        // Defaults to false, but a state file that already knows about notes plainly had a vault —
        // so an upgrade from a build predating this flag does not get offered a fresh welcome note.
        vaultEverCreated =
            try c.decodeIfPresent(Bool.self, forKey: .vaultEverCreated) ?? !notes.isEmpty
        lastUpdateCheck = try c.decodeIfPresent(Date.self, forKey: .lastUpdateCheck)
        availableUpdate = try c.decodeIfPresent(String.self, forKey: .availableUpdate)
    }
}

// MARK: - Convenience

extension AppState {

    public func note(_ filename: String) -> NoteState {
        notes[filename] ?? NoteState()
    }

    public var pinnedFilenames: [String] {
        notes.filter(\.value.isPinned).keys.sorted()
    }

    /// The note to open on the next summon: the one most recently opened.
    ///
    /// Reads from `notes` rather than from a dedicated "last used" field so there is one source of
    /// truth — a separate field would be a second place for the answer to be wrong.
    public var lastUsedFilename: String? {
        notes
            .compactMap { name, state in state.lastOpened.map { (name, $0) } }
            .max { $0.1 < $1.1 }?
            .0
    }

    public mutating func recordOpen(_ filename: String, at date: Date) {
        var s = notes[filename] ?? NoteState()
        s.lastOpened = date
        notes[filename] = s
    }

    public mutating func recordCaret(
        _ filename: String,
        offset: Int,
        anchor: Int? = nil,
        scrollLine: Int = 0
    ) {
        var s = notes[filename] ?? NoteState()
        s.caretOffset = max(0, offset)
        s.selectionAnchor = anchor.map { max(0, $0) }
        s.scrollLine = max(0, scrollLine)
        notes[filename] = s
    }

    @discardableResult
    public mutating func togglePin(_ filename: String) -> Bool {
        var s = notes[filename] ?? NoteState()
        s.isPinned.toggle()
        notes[filename] = s
        return s.isPinned
    }

    /// Drops state for notes that no longer exist, so a long-lived vault does not accumulate an
    /// entry for every note ever deleted.
    ///
    /// Deliberately *not* called while the vault is unreachable or a note is still downloading from
    /// iCloud — an evicted or temporarily missing note is not a deleted one, and forgetting its pin
    /// and caret because a sync was slow would be the same class of bug as decision 13's.
    public mutating func forgetNotes(missingFrom present: Set<String>) {
        notes = notes.filter { present.contains($0.key) }
        for i in panels.indices where panels[i].noteFilename.map({ !present.contains($0) }) ?? false {
            panels[i].noteFilename = nil
        }
    }
}
