import AppKit
import PlumeKit

/// The About tab — what you are running, and whether it is the latest.
///
/// Not in the design record: frames 2c and 3a–3c draw four tabs and this is a fifth. It is here
/// because the app had no route to its own version at all, which for an unsigned build distributed
/// as a zip and a cask is a real gap: "which one am I on" had no answer inside the app.
///
/// **This button is one of the two callers of Plume's only network call.** Decision 7 says no server,
/// no account, no protocol, and telemetry is on the not-doing list; a version check is none of
/// those, and nothing is sent but the request itself. Decision 9 is untouched: an outgoing HTTPS
/// request needs no entitlement and no privacy permission, so `Info.plist` gains nothing.
///
/// **Amended: "only when this button is pressed" is no longer true.** The same request is made on
/// summon, about once a day, so that somebody on an old build finds out — see decision 136 and
/// `ReleaseFetcher`. Nothing fires on *launch* and nothing is on a *timer*, which is the half of 94
/// that survives: both callers are a press or a keypress, so the request only happens with a person
/// at the keyboard. This button remains the way to ask on purpose, and it works with the setting
/// switched off, because pressing it is asking.
///
/// It also does not download, install, or open anything. Plume is unsigned (decision 9), so an
/// auto-updater would need a signing story the project does not have — and the install path is a
/// Homebrew cask, which already knows how to upgrade. The button's whole job is to answer the
/// question; `brew upgrade --cask plume` or the Releases link does the rest.
@MainActor
final class AboutSettingsViewController: NSViewController {

    private static let releasesPage = ReleaseFetcher.releasesPage
    private static let repository = URL(string: "https://github.com/tiylabs/plume")!
    private static let licenseFile = URL(string: "https://github.com/tiylabs/plume/blob/master/LICENSE")!

    /// Hands each answer to the same place the summon check's goes, so the menu bar item and the
    /// icon's dot light from a press here too.
    var onStatus: ((ReleaseCheck.Status) -> Void)?

    private var status: NSTextField!
    private var checkButton: NSButton!

    /// `CFBundleShortVersionString`, which `build-app.sh` writes from the tag.
    private var version: String { ReleaseFetcher.runningVersion }

    init() {
        super.init(nibName: nil, bundle: nil)
        title = tr("settings.tab.about")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

        let name = NSTextField(labelWithString: BuildProfile.current.displayName)
        name.font = .systemFont(ofSize: 15, weight: .semibold)

        // The version and nothing else. A build number is ours rather than the reader's — it says
        // nothing they can act on, and the release it belongs to is the thing they would quote.
        let versionLabel = NSTextField(labelWithString: tr("about.version", ["version": version]))
        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .secondaryLabelColor

        checkButton = SettingsForm.push(
            tr("about.check"), target: self, action: #selector(checkForUpdates)
        )

        // Empty until the button is pressed, and it takes no height while it is — decision 76's
        // rule met by a layout: a line that is not saying anything should not be reserving space
        // for the moment it might.
        status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.isHidden = true

        // Hero: icon, name, version, and the one action. Centred in the card width, with the status
        // line under the button taking no height until a check has been made.
        let hero = NSStackView(views: [icon, name, versionLabel, checkButton, status])
        hero.orientation = .vertical
        hero.alignment = .centerX
        hero.spacing = 10
        hero.setCustomSpacing(4, after: name)
        hero.setCustomSpacing(16, after: versionLabel)
        hero.translatesAutoresizingMaskIntoConstraints = false

        let heroBlock = NSView()
        heroBlock.addSubview(hero)
        NSLayoutConstraint.activate([
            hero.topAnchor.constraint(equalTo: heroBlock.topAnchor, constant: 8),
            hero.bottomAnchor.constraint(equalTo: heroBlock.bottomAnchor, constant: -4),
            hero.centerXAnchor.constraint(equalTo: heroBlock.centerXAnchor),
        ])

        // Links are rows like any other, so they line up with every other tab's cards.
        let form = SettingsForm()
        form.block(heroBlock)
        form.card([
            linkRow(tr("about.github"), to: Self.repository),
            linkRow(tr("about.releases"), to: Self.releasesPage),
            linkRow(tr("about.license"), to: Self.licenseFile),
        ])
        view = form.makeContentView()
    }

    private func linkRow(_ title: String, to url: URL) -> SettingsRow {
        let open = NSButton(
            image: NSImage(
                systemSymbolName: "arrow.up.right.square", accessibilityDescription: title
            ) ?? NSImage(),
            target: self,
            action: #selector(openLink(_:))
        )
        open.isBordered = false
        open.contentTintColor = .secondaryLabelColor
        open.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
        open.setAccessibilityLabel(title)
        return SettingsRow(title: title, control: open)
    }

    func settingsChanged(_ new: Settings) {}

    @objc private func openLink(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func checkForUpdates() {
        checkButton.isEnabled = false
        status.stringValue = tr("about.checking")
        status.isHidden = false

        ReleaseFetcher.fetchStatus { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.checkButton.isEnabled = true
                    self.onStatus?(result)

                    switch result {
                    case .behind(let latest):
                        // Named, and nothing more. Pressing "check" is a request to be told, not a
                        // request to open a browser — the Releases link below is right there, and
                        // launching one unasked is the app doing something you did not press.
                        self.status.stringValue = tr("about.available", ["version": latest])
                    case .current:
                        self.status.stringValue = tr("about.upToDate")
                    case .unknown:
                        // Named as what happened, not explained (decision 76). "Could not check" is
                        // the fact; whether it was DNS, a rate limit or a captive portal is not
                        // something the reader can act on differently.
                        self.status.stringValue = tr("about.failed")
                    }
                }
            }
        }
    }
}
