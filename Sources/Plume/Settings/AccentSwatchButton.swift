import AppKit
import PlumeKit

/// One accent dot, drawn as the design draws it: a filled circle, and a ring around the chosen one.
///
/// A custom button rather than `NSColorWell` because the design offers a fixed set rather than the
/// whole colour space — decision 22 reserves accent for interactive state, and a free-for-all picker
/// invites an accent that fails against the panel's material.
@MainActor
final class AccentSwatchButton: NSButton {

    let hex: String
    private let darkHex: String

    var isChosen = false {
        didSet {
            setAccessibilityValue(isChosen ? 1 : 0)
            needsDisplay = true
        }
    }

    init(hex: String, darkHex: String, name: String) {
        self.hex = hex
        self.darkHex = darkHex
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        toolTip = name
        setAccessibilityLabel(name)
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let colour = NSColor(hex: isDark ? darkHex : hex) ?? .controlAccentColor
        let dot = bounds.insetBy(dx: 3, dy: 3)

        colour.setFill()
        NSBezierPath(ovalIn: dot).fill()

        guard isChosen else { return }
        // A gap between the dot and the ring, so the ring reads as selection rather than as a border
        // the swatch always had.
        colour.setStroke()
        let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
        ring.lineWidth = 1.5
        ring.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
