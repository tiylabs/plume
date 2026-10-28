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

    /// Kept separately so wrapping can use the control's fitted width, not the label's last frame.
    private var rowControl: NSView?

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
        rowControl = control
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

    /// Measures wrapping against the space available beside the control, capped at 280 points.
    ///
    /// The MCP access pop-up can leave less than 280 points for its explanation; measuring at 280
    /// clipped the third line. But measuring the label's own frame feeds its new intrinsic size back
    /// into the next measurement: Storage's iCloud explanation and Git status row oscillated between
    /// widths until AppKit threw an update-constraints-loop exception. Use the row's inner width minus
    /// the control's fitting width, which does not depend on the explanation's intrinsic size. Hidden
    /// Git cards have no useful layout allocation and must wait until they are shown before measuring.
    override func layout() {
        super.layout()
        guard !explanationLabel.isHiddenOrHasHiddenAncestor, explanationLabel.superview != nil else { return }
        let controlWidth = rowControl.map { $0.fittingSize.width + SettingsForm.rowSpacing } ?? 0
        let width = min(bounds.width - 2 * SettingsForm.rowInset - controlWidth, SettingsForm.explanationWidth)
        guard width > 0, abs(explanationLabel.preferredMaxLayoutWidth - width) > 0.5 else { return }
        explanationLabel.preferredMaxLayoutWidth = width
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
