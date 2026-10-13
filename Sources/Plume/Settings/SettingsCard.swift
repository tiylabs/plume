import AppKit
import PlumeKit

/// A rounded group of rows with a hairline between them.
@MainActor
final class SettingsCard: NSView {

    /// White in light; a faint lift off the window in dark. Resolved per appearance in `updateLayer`,
    /// because a `CGColor` does not follow the appearance on its own.
    private static let fill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.07) : .white
    }

    init(rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = SettingsForm.cardRadius
        layer?.borderWidth = 0.5

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        for (index, row) in rows.enumerated() {
            if index > 0 {
                let divider = Self.divider()
                column.addArrangedSubview(divider)
                divider.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
            row.translatesAutoresizingMaskIntoConstraints = false
            column.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Inset on both sides by the row padding, so it stops short of the rounded corners.
    private static func divider() -> NSView {
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(
                equalTo: wrap.leadingAnchor, constant: SettingsForm.rowInset
            ),
            line.trailingAnchor.constraint(
                equalTo: wrap.trailingAnchor, constant: -SettingsForm.rowInset
            ),
            line.centerYAnchor.constraint(equalTo: wrap.centerYAnchor),
        ])
        return wrap
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Self.fill.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        needsDisplay = true
    }
}
