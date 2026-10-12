import AppKit
import PlumeKit

/// The Settings window's layout system — one page builder, one card, one row, shared by every tab.
///
/// The spec is `Design/Specs/settings-design-spec.md`; the numbers below are its tokens, and this is the one
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
