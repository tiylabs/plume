import AppKit
import PlumeKit

/// The same recorder, for a shortcut that is a CodeMirror binding rather than a Carbon hotkey.
///
/// Separate from `HotkeyRecorderView` because the two produce different things and validate
/// differently: a global hotkey must carry a modifier or it would swallow that key system-wide, while
/// an in-panel binding must carry one for a much smaller reason — it lives in a text editor, so an
/// unmodified key is a character somebody wanted to type.
@MainActor
final class ShortcutRecorderView: HotkeyRecorderViewBase {

    var onRecord: ((String) -> Void)?

    private var binding: String

    init(binding: String) {
        self.binding = binding
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func setBinding(_ binding: String) {
        self.binding = binding
        needsDisplay = true
    }

    override var displayText: String { Self.symbols(for: binding) }

    override func handle(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Bool {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("Ctrl") }
        if flags.contains(.option) { parts.append("Alt") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Mod") }
        guard !parts.isEmpty else { return false }

        guard let key = Self.bindingKey(for: keyCode) else { return false }
        parts.append(key)

        binding = parts.joined(separator: "-")
        onRecord?(binding)
        return true
    }

    /// CodeMirror names keys by `KeyboardEvent.key`, so this maps the hardware code to that name.
    private static func bindingKey(for keyCode: UInt16) -> String? {
        KeyCode.bindingName(for: UInt32(keyCode))
    }

    /// Renders `"Shift-Mod-p"` as `⇧⌘P`, in Apple's display order rather than the binding's.
    static func symbols(for binding: String) -> String {
        var pieces = binding.split(separator: "-").map(String.init)
        guard let key = pieces.popLast() else { return "" }

        let held = Set(pieces)
        var s = ""
        if held.contains("Ctrl") { s += "⌃" }
        if held.contains("Alt") { s += "⌥" }
        if held.contains("Shift") { s += "⇧" }
        if held.contains("Mod") || held.contains("Cmd") { s += "⌘" }
        return s + (key.count == 1 ? key.uppercased() : key)
    }
}
