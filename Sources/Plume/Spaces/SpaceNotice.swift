import AppKit

/// "Plume is on Desktop 2" — said on the desktop being looked at, because the panel is not on it.
///
/// A summon of a panel kept to one desktop (`SpaceAssignment.oneSpace`) from anywhere else does not
/// move it, and a summon that visibly does nothing reads as a hotkey that broke. The panel's own
/// toast cannot say so: it is a web view on the other desktop. So this is its own window, styled as
/// the auto-size pill is, centred on the screen under the pointer a little above the middle, and gone
/// on its own.
@MainActor
final class SpaceNotice {

    /// Long enough to read a short line twice; short enough not to be in the way of what you were
    /// doing, which is the thing you summoned *from*.
    private static let dwell: TimeInterval = 2

    private let panel: NSPanel
    private let label: NSTextField
    private var hideTask: Task<Void, Never>?
    /// Bumped by every `show`, so a fade that finishes after a newer notice began leaves it alone.
    private var generation = 0

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        // On whatever desktop is being looked at, which is the whole point of it.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        // The auto-size pill's material and wash, so the two read as the same family.
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 17
        background.layer?.masksToBounds = true

        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.55).cgColor
        tint.translatesAutoresizingMaskIntoConstraints = false

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(tint)
        background.addSubview(label)
        NSLayoutConstraint.activate([
            tint.topAnchor.constraint(equalTo: background.topAnchor),
            tint.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            tint.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            tint.trailingAnchor.constraint(equalTo: background.trailingAnchor),

            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
        ])

        panel.contentView = background
    }

    func show(_ text: String) {
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
        else { return }

        label.stringValue = text
        let size = CGSize(width: label.intrinsicContentSize.width + 36, height: 34)
        let visible = screen.visibleFrame
        let origin = CGPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.minY + visible.height * 0.7 - size.height / 2).rounded()
        )
        panel.setFrame(CGRect(origin: origin, size: size), display: true)

        hideTask?.cancel()
        generation += 1
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0.95
        }

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.dwell))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func hide() {
        let fading = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // Guarded: a second summon may have brought it back during the fade.
                guard let self, self.generation == fading else { return }
                self.panel.orderOut(nil)
            }
        }
    }
}
