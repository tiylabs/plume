import AppKit
import PlumeKit

/// The Settings window's layout system — one page builder, one card, one row, shared by every tab.
///
/// The spec is `Design/settings-design-spec.md`; the numbers below are its tokens, and this is the one
/// place they are written down. A tab never sets a margin, a width or a font of its own.
///
/// The shape is macOS System Settings': a page is a column of **cards**; a card is a rounded group of
/// **rows**; a row is a title (and an optional one-line explanation) on the left and its control on
/// the right, with a hairline between rows. A caption can sit above a card (`header`) or below it
/// (`footnote`). That replaces the previous right-aligned label column, whose width differed per tab —
/// so controls started at a different x on every page and nothing lined up across tabs.
///
/// Colours and fonts come from AppKit rather than from `tokens.css`: the greys *are* macOS's own label
/// colours, and hard-coding them would mean a window that ignores Increase Contrast and gets dark
/// mode wrong by hand.
@MainActor
final class SettingsForm {

    // MARK: - Tokens

    /// Every tab is this wide. `NSTabViewController` sizes the window to whichever tab is showing, so
    /// a tab that disagrees makes the *window* change width as you switch tabs.
    static let contentWidth: CGFloat = 540
    /// Page margin, left and right.
    static let pageInset: CGFloat = 24
    static let pageTop: CGFloat = 20
    static let pageBottom: CGFloat = 28
    /// A card is always this wide; captions and the footer button share it so every edge lines up.
    static let cardWidth: CGFloat = contentWidth - 2 * pageInset
    /// Between two cards.
    static let cardGap: CGFloat = 16
    /// Between a card and the caption that belongs to it.
    static let captionGap: CGFloat = 6
    static let cardRadius: CGFloat = 10
    /// Inside a row, left and right — and the indent of dividers and captions, so text lines up.
    static let rowInset: CGFloat = 14
    static let rowVerticalPadding: CGFloat = 8
    static let rowMinHeight: CGFloat = 40
    /// Between a row's text and its control.
    static let rowSpacing: CGFloat = 12
    /// A row's explanation wraps here, which keeps it clear of the control beside it.
    static let explanationWidth: CGFloat = 280
    /// Every pop-up is at least this wide, so a card's right edge is not a ragged line.
    static let popUpMinWidth: CGFloat = 150

    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let explanationFont = NSFont.systemFont(ofSize: 11)
    static let captionHeaderFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    // MARK: - Page

    private let stack: NSStackView

    init() {
        stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.cardGap
        stack.translatesAutoresizingMaskIntoConstraints = false
    }

    /// A card of rows.
    @discardableResult
    func card(_ rows: [NSView]) -> SettingsCard {
        let card = SettingsCard(rows: rows)
        add(card)
        return card
    }

    /// A quiet group name above the next card.
    func header(_ text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = Self.captionHeaderFont
        label.textColor = .secondaryLabelColor
        let caption = Self.caption(label)
        add(caption)
        stack.setCustomSpacing(Self.captionGap, after: caption)
    }

    /// A note under the card above it. Pulled up close so it reads as that card's, not as a row.
    @discardableResult
    func footnote(_ text: String) -> NSView {
        if let last = stack.arrangedSubviews.last {
            stack.setCustomSpacing(Self.captionGap, after: last)
        }
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = Self.explanationFont
        label.textColor = .secondaryLabelColor
        let caption = Self.caption(label)
        add(caption)
        return caption
    }

    /// A control right-aligned to the card edge — the Restore Defaults button.
    @discardableResult
    func trailing(_ control: NSView) -> NSView {
        let wrap = NSView()
        control.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(control)
        NSLayoutConstraint.activate([
            control.topAnchor.constraint(equalTo: wrap.topAnchor),
            control.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            control.trailingAnchor.constraint(equalTo: wrap.trailingAnchor),
        ])
        add(wrap)
        return wrap
    }

    /// Any other full-width block — the About tab's centred header. It is given the card width so its
    /// centre is the card's centre.
    func block(_ view: NSView) {
        add(view)
    }

    private func add(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true
    }

    private static func caption(_ label: NSTextField) -> NSView {
        let wrap = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = cardWidth - 2 * rowInset
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        wrap.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: wrap.topAnchor),
            label.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: rowInset),
            label.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -rowInset),
        ])
        return wrap
    }

    /// Wraps the page in a view of the shared width, ready to be a tab's content.
    func makeContentView() -> NSView {
        let container = NSView()
        container.addSubview(stack)

        // `NSTabViewController` sizes its container to the *tallest* tab and stretches the others to
        // match. So the page is pinned to the top only and told to hug its content: the container is
        // free to be taller than the page without any of that height reaching the rows.
        stack.setContentHuggingPriority(.required, for: .vertical)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.pageTop),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.pageInset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.pageInset),
            container.bottomAnchor.constraint(
                greaterThanOrEqualTo: stack.bottomAnchor, constant: Self.pageBottom
            ),
            container.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])
        return container
    }

    // MARK: - Controls

    static func toggle(_ isOn: Bool, target: AnyObject, action: Selector) -> NSSwitch {
        let toggle = NSSwitch()
        // `.small`: the regular switch is 38×22 with a heavy blue fill, and next to a 22pt pop-up it
        // out-weighs it. Small is ~32×18, which sits on the same visual line as the other controls.
        toggle.controlSize = .small
        toggle.state = isOn ? .on : .off
        toggle.target = target
        toggle.action = action
        return toggle
    }

    static func popUp(_ titles: [String], target: AnyObject, action: Selector) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: titles)
        popUp.target = target
        popUp.action = action
        popUp.font = titleFont
        popUp.widthAnchor.constraint(greaterThanOrEqualToConstant: popUpMinWidth).isActive = true
        return popUp
    }

    static func push(_ title: String, target: AnyObject, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.font = titleFont
        return button
    }

    /// A read-only value in a row's control slot.
    static func value(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = titleFont
        field.textColor = .secondaryLabelColor
        return field
    }

    /// A path shown the way the design draws it — monospaced, in a recessed field, not editable.
    ///
    /// Not an `NSTextField` the user can type into: the vault has to exist, and the way to say that
    /// is a Change… button and an open panel rather than validating a hand-typed path on every
    /// keystroke.
    static func pathField(_ path: String) -> NSTextField {
        let field = NSTextField(labelWithString: path)
        field.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
}

// MARK: - Card

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

// MARK: - Row

/// Title (and an optional explanation) on the left, control on the right.
@MainActor
final class SettingsRow: NSView {

    /// Hidden while empty, and a hidden view takes no height in a stack, so a row with nothing to
    /// explain is not reserving space for the moment it might.
    let explanationLabel: NSTextField

    /// The row's title, for the one row that changes its mind about what it is called.
    let titleLabel: NSTextField

    init(title: String, explanation: String? = nil, control: NSView? = nil) {
        let titleLabel = NSTextField(labelWithString: title)
        self.titleLabel = titleLabel
        titleLabel.font = SettingsForm.titleFont
        titleLabel.lineBreakMode = .byTruncatingTail

        explanationLabel = NSTextField(wrappingLabelWithString: explanation ?? "")
        explanationLabel.font = SettingsForm.explanationFont
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.preferredMaxLayoutWidth = SettingsForm.explanationWidth
        explanationLabel.isHidden = (explanation ?? "").isEmpty
        explanationLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        super.init(frame: .zero)

        let text = NSStackView(views: [titleLabel, explanationLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        // `line` is exactly as tall as the taller of title and control, and both sit on its centre.
        //
        // Two things were tried first and both failed. Pinning the text to the row's top and bottom
        // padding at once is unsatisfiable whenever the control is the taller one, and the solver
        // drops one side — so titles hung from the top edge, above their own control. And pinning
        // nothing inwards let the card stretch a row to 400 points. The fix is one container: required
        // `>=` constraints make it at least as tall as each child, and a weak `height == 0` squeezes
        // it down to the tallest of them and no further.
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        text.translatesAutoresizingMaskIntoConstraints = false
        line.addSubview(text)

        var constraints = [
            text.leadingAnchor.constraint(equalTo: line.leadingAnchor),
            text.centerYAnchor.constraint(equalTo: line.centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: line.topAnchor),
            text.bottomAnchor.constraint(lessThanOrEqualTo: line.bottomAnchor),
        ]
        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.setContentHuggingPriority(.required, for: .horizontal)
            control.setContentCompressionResistancePriority(.required, for: .horizontal)
            // The row's title is the only name a switch or a pop-up has for VoiceOver.
            if control.accessibilityLabel() == nil { control.setAccessibilityLabel(title) }
            line.addSubview(control)
            constraints += [
                control.trailingAnchor.constraint(equalTo: line.trailingAnchor),
                control.centerYAnchor.constraint(equalTo: line.centerYAnchor),
                control.topAnchor.constraint(greaterThanOrEqualTo: line.topAnchor),
                control.bottomAnchor.constraint(lessThanOrEqualTo: line.bottomAnchor),
                // The control is pinned to the right edge and the text is bounded by it, so every
                // control in the window ends on the same x.
                text.trailingAnchor.constraint(
                    lessThanOrEqualTo: control.leadingAnchor, constant: -SettingsForm.rowSpacing
                ),
            ]
        } else {
            constraints.append(text.trailingAnchor.constraint(lessThanOrEqualTo: line.trailingAnchor))
        }
        let squeeze = line.heightAnchor.constraint(equalToConstant: 0)
        squeeze.priority = .defaultLow
        constraints.append(squeeze)
        NSLayoutConstraint.activate(constraints)

        embed(line)
    }

    /// A row that is one view end to end, for content that is not a title and a control.
    init(content: NSView) {
        explanationLabel = NSTextField(labelWithString: "")
        titleLabel = NSTextField(labelWithString: "")
        super.init(frame: .zero)
        embed(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func embed(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(
                equalTo: topAnchor, constant: SettingsForm.rowVerticalPadding
            ),
            content.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -SettingsForm.rowVerticalPadding
            ),
            content.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: SettingsForm.rowInset
            ),
            content.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -SettingsForm.rowInset
            ),
            heightAnchor.constraint(greaterThanOrEqualToConstant: SettingsForm.rowMinHeight),
        ])
    }
}

extension Settings.Appearance {
    /// `nil` means "follow the system", which is what `NSWindow.appearance` does when unset.
    var nsAppearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}
