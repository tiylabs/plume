import Foundation

/// Everything Swift can ask the page to do: one case per method of `HostAPI` in
/// `Editor/src/bridge/protocol.ts`.
///
/// Replaces `editor.call("loadNote", [a, b, c, d])`, where the method name was a string and the
/// arguments an untyped array, so a renamed method or a missing argument was a silent no-op in the
/// web view. Here a wrong name does not compile, and `BridgeContractTests` checks the names and the
/// argument counts against the TypeScript interface.
///
/// **Arguments are JSON-encoded, never interpolated.** A note containing a backtick, a newline or
/// `</script>` is completely ordinary, and concatenating one into a JavaScript expression would
/// break the editor on exactly the content people write.
public enum EditorCommand: Equatable, Sendable {
    case loadNote(filename: String, text: String, caret: Int, pinned: Bool)
    case focusEditor
    case resetHistory
    case setNoteFilename(String)
    case setPinned(Bool)
    case setFocused(Bool)
    case applySettings(PanelSettingsPayload)
    case showNotes([SwitcherRow], total: Int, query: String)
    case showDeleted([SwitcherRow])
    case setHiddenFromCapture(Bool)
    case setKeepOnTop(Bool)
    case setSpaceAssignment(mode: String, desktop: Int?, canKeepToOne: Bool)
    case setDockSpaceAssignment(mode: String, desktop: Int?)
    case setAutoSizing(Bool)
    case setCloseHover(Bool)
    case setHover(Bool)
    case setPointer(x: Double, y: Double)
    case openSwitcher
    case openActions
    case setHeadingLevel(Int)
    case showToast(String, dwell: Int? = nil)
    case showBanner(kind: String, text: String)
    case hideBanner

    /// The method on `window.plumeHost`.
    public var method: String {
        switch self {
        case .loadNote: "loadNote"
        case .focusEditor: "focusEditor"
        case .resetHistory: "resetHistory"
        case .setNoteFilename: "setNoteFilename"
        case .setPinned: "setPinned"
        case .setFocused: "setFocused"
        case .applySettings: "applySettings"
        case .showNotes: "showNotes"
        case .showDeleted: "showDeleted"
        case .setHiddenFromCapture: "setHiddenFromCapture"
        case .setKeepOnTop: "setKeepOnTop"
        case .setSpaceAssignment: "setSpaceAssignment"
        case .setDockSpaceAssignment: "setDockSpaceAssignment"
        case .setAutoSizing: "setAutoSizing"
        case .setCloseHover: "setCloseHover"
        case .setHover: "setHover"
        case .setPointer: "setPointer"
        case .openSwitcher: "openSwitcher"
        case .openActions: "openActions"
        case .setHeadingLevel: "setHeadingLevel"
        case .showToast: "showToast"
        case .showBanner: "showBanner"
        case .hideBanner: "hideBanner"
        }
    }

    /// Every method name, derived from the cases rather than listed twice. A new case has to appear
    /// in `method` (exhaustive switch) and in `samples`, which the contract test walks.
    public static var allMethods: Set<String> { Set(samples.map(\.method)) }

    /// One value of each case. `Equatable` enums with payloads cannot be `CaseIterable`, so this is
    /// the enumeration; the contract test checks it covers every `HostAPI` method, which is what
    /// stops a case being added and forgotten here.
    public static var samples: [EditorCommand] {
        [
            .loadNote(filename: "", text: "", caret: 0, pinned: false),
            .focusEditor, .resetHistory, .setNoteFilename(""), .setPinned(false), .setFocused(false),
            .applySettings(PanelSettingsPayload()),
            .showNotes([], total: 0, query: ""), .showDeleted([]),
            .setHiddenFromCapture(false), .setKeepOnTop(false),
            .setSpaceAssignment(mode: "", desktop: nil, canKeepToOne: false),
            .setDockSpaceAssignment(mode: "", desktop: nil),
            .setAutoSizing(false), .setCloseHover(false), .setHover(false), .setPointer(x: 0, y: 0),
            .openSwitcher, .openActions, .setHeadingLevel(0),
            .showToast("", dwell: nil), .showBanner(kind: "", text: ""), .hideBanner,
        ]
    }

    // MARK: - Encoding

    /// The arguments, each already JSON, in the order the method takes them.
    public func encodedArguments() -> [String] {
        switch self {
        case .loadNote(let filename, let text, let caret, let pinned):
            [Self.json(filename), Self.json(text), Self.json(caret), Self.json(pinned)]
        case .focusEditor, .resetHistory, .openSwitcher, .openActions, .hideBanner:
            []
        case .setNoteFilename(let value): [Self.json(value)]
        case .setPinned(let value), .setFocused(let value), .setHiddenFromCapture(let value),
             .setKeepOnTop(let value), .setAutoSizing(let value), .setCloseHover(let value),
             .setHover(let value):
            [Self.json(value)]
        case .applySettings(let payload): [Self.json(payload)]
        case .showNotes(let rows, let total, let query): [Self.json(rows), Self.json(total), Self.json(query)]
        case .showDeleted(let rows): [Self.json(rows)]
        case .setSpaceAssignment(let mode, let desktop, let canKeepToOne):
            [Self.json(mode), Self.json(desktop), Self.json(canKeepToOne)]
        case .setDockSpaceAssignment(let mode, let desktop): [Self.json(mode), Self.json(desktop)]
        case .setPointer(let x, let y): [Self.json(x), Self.json(y)]
        case .setHeadingLevel(let level): [Self.json(level)]
        case .showToast(let text, let dwell):
            dwell.map { [Self.json(text), Self.json($0)] } ?? [Self.json(text)]
        case .showBanner(let kind, let text): [Self.json(kind), Self.json(text)]
        }
    }

    /// The JavaScript to evaluate. Guarded on `window.plumeHost` because the page may not have
    /// finished loading; callers queue the script until the page reports ready.
    public var script: String {
        "window.plumeHost && window.plumeHost.\(method)(\(encodedArguments().joined(separator: ", ")));"
    }

    /// One value as JSON. `nil` is `null`, which is how an absent desktop crosses.
    private static func json<T: Encodable>(_ value: T) -> String {
        // Slashes stay escaped (`<\/script>`), as `JSONSerialization` always wrote them: harmless in
        // `evaluateJavaScript`, but not worth being the one thing this refactor changed.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // A top-level fragment (a bare string or number) is valid for JSONEncoder on every OS this
        // targets, so no wrapper array is needed — and Optional.none encodes as `null`.
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return text
    }
}

/// What `applySettings` carries. Keys are exactly those `PanelSettings` in protocol.ts names.
public struct PanelSettingsPayload: Encodable, Equatable, Sendable {
    public var appearance: String?
    public var accent: String?
    public var accentDark: String?
    public var textSize: Double?
    public var footerCount: String?
    public var panelOpacity: Double?
    public var glass: Bool?
    public var shortcuts: [String: String]?
    public var themeCSS: String?
    public var language: String?

    public init(
        appearance: String? = nil, accent: String? = nil, accentDark: String? = nil,
        textSize: Double? = nil, footerCount: String? = nil, panelOpacity: Double? = nil,
        glass: Bool? = nil, shortcuts: [String: String]? = nil, themeCSS: String? = nil,
        language: String? = nil
    ) {
        self.appearance = appearance
        self.accent = accent
        self.accentDark = accentDark
        self.textSize = textSize
        self.footerCount = footerCount
        self.panelOpacity = panelOpacity
        self.glass = glass
        self.shortcuts = shortcuts
        self.themeCSS = themeCSS
        self.language = language
    }
}
