import AppKit
import PlumeKit

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

    /// Wraps the explanation at the width it actually got.
    ///
    /// `explanationWidth` is the most it may take, but a wide control takes some of it. The MCP
    /// tab's access pop-up, when its longest option was "Read, create and change notes", left the
    /// English explanation narrower than 280; the label still measured its height at 280 — two
    /// lines — and the third was cut off. Re-measuring at the real width gives any row the lines it
    /// needs, whatever control sits beside it.
    override func layout() {
        super.layout()
        let width = explanationLabel.frame.width
        guard !explanationLabel.isHidden, width > 0,
              abs(explanationLabel.preferredMaxLayoutWidth - width) > 0.5 else { return }
        explanationLabel.preferredMaxLayoutWidth = min(width, SettingsForm.explanationWidth)
        explanationLabel.invalidateIntrinsicContentSize()
        needsLayout = true
    }

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
