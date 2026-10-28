import AppKit
import PlumeKit
@testable import Plume

/// Runs against the app's compiled types, without its entry point or any live vault services.
@main
@MainActor
struct SettingsLayoutTests {
    private static var assertions = 0

    static func main() {
        setbuf(stdout, nil)
        // A layout loop must fail the gate even on AppKit versions that hang instead of throwing.
        alarm(30)
        defer { alarm(0) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        L10n.configure(directory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["PLUME_LOCALES"]!))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for language in ["en", "zh-Hans"] {
            L10n.setLanguage(language)
            storageLayouts(root: root.appendingPathComponent(language))
            rowLayouts()
            tabLayouts(root: root.appendingPathComponent(language))
        }
        print("✓ native Settings layouts, \(assertions) assertions, all passing")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else {
            FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func window(containing view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: SettingsForm.contentWidth, height: 700),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        settle(view)
        return window
    }

    private static func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        view.layoutSubtreeIfNeeded()
    }

    private static func rows(in view: NSView) -> [SettingsRow] {
        (view as? SettingsRow).map { [$0] } ?? view.subviews.flatMap { rows(in: $0) }
    }

    private static func stable(_ view: NSView) {
        settle(view)
        rows(in: view).forEach { $0.needsLayout = true }
        settle(view)
        let labels = rows(in: view).map(\.explanationLabel)
        let before = labels.map { ($0.preferredMaxLayoutWidth, $0.frame) }
        for _ in 0..<4 {
            rows(in: view).forEach { $0.needsLayout = true }
            settle(view)
        }
        for (label, old) in zip(labels, before) {
            check(abs(label.preferredMaxLayoutWidth - old.0) < 0.5, "wrapping width must settle: \(label.stringValue)")
            check(abs(label.frame.height - old.1.height) < 0.5, "explanation height must settle")
        }
    }

    private static func storageLayouts(root: URL) {
        let settings = SettingsStore(
            store: JSONFileStore(url: root.appendingPathComponent("settings.json")), profile: .release
        )
        settings.update { $0.vaultPath = root.appendingPathComponent("vault").path }
        let storage = StorageSettingsViewController(settings: settings)
        print("Checking Storage: \(L10n.currentLanguage), local / iCloud / Git transitions")
        let window = window(containing: storage.view)
        defer { window.orderOut(nil) }
        stable(storage.view)
        let connection = rows(in: storage.view).first { $0.titleLabel.stringValue == L10n.t("storage.git.connection") }!
        check(connection.isHiddenOrHasHiddenAncestor, "Git connection card starts hidden")
        check(connection.explanationLabel.preferredMaxLayoutWidth == SettingsForm.explanationWidth,
              "hidden cards must not remeasure explanations")

        // Only the configuration changes. No folder moves, cloud downloads or git operations run.
        settings.update { $0.vaultPath = "~/Library/Mobile Documents/com~apple~CloudDocs/Plume" }
        storage.settingsChanged(settings.value)
        stable(storage.view)
        let sync = rows(in: storage.view).first { $0.titleLabel.stringValue == L10n.t("storage.sync") }!
        check(!sync.explanationLabel.isHiddenOrHasHiddenAncestor, "iCloud explanation is visible")
        check(sync.explanationLabel.stringValue == L10n.t("storage.syncedNote"), "iCloud explanation is populated")

        settings.update { $0.vaultPath = root.appendingPathComponent("vault").path }
        storage.settingsChanged(settings.value)
        let popup = sync.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSPopUpButton }.first!
        popup.selectItem(at: 2)
        _ = popup.target?.perform(popup.action!, with: popup)
        stable(storage.view)
        check(!connection.isHiddenOrHasHiddenAncestor, "choosing Git reveals the verification explanation")
        check(!settings.value.gitSync.enabled, "choosing Git does not start synchronization")

        settings.update { $0.gitSync = GitSyncSettings(enabled: true, remoteURL: "git@example.invalid:notes.git", branch: "main") }
        storage.settingsChanged(settings.value)
        for status: GitSyncStatus in [
            .idle(lastSync: nil), .syncing, .failed(.authenticationFailed),
            .failed(.other(String(repeating: "Long verification detail with spaces. ", count: 10))),
            .conflicts(["one.md", "two.md"]), .idle(lastSync: Date()),
        ] {
            storage.syncStatusChanged(status)
            stable(storage.view)
        }
        settings.update { $0.gitSync.enabled = false }
        storage.settingsChanged(settings.value)
        stable(storage.view)
    }

    private static func tabLayouts(root: URL) {
        let settings = SettingsStore(
            store: JSONFileStore(url: root.appendingPathComponent("tabs.json")), profile: .release
        )
        settings.update { $0.vaultPath = root.appendingPathComponent("vault").path }
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for controller in [
            GeneralSettingsViewController(settings: settings), StorageSettingsViewController(settings: settings),
            AppearanceSettingsViewController(settings: settings), ShortcutsSettingsViewController(settings: settings),
            AboutSettingsViewController(),
        ] as [NSViewController] {
            controller.preferredContentSize = NSSize(width: SettingsForm.contentWidth, height: 700)
            tabs.addTabViewItem(NSTabViewItem(viewController: controller))
        }
        let window = NSWindow(contentViewController: tabs)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .preference
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        print("Checking toolbar tabs: \(L10n.currentLanguage), repeated switches to Storage")
        for index in [0, 1, 2, 1, 3, 1, 4, 1] {
            tabs.selectedTabViewItemIndex = index
            let page = tabs.tabViewItems[index].viewController!.view
            stable(page)
            check(page.window === window, "selected settings page is attached to the real window")
        }
    }

    private static func rowLayouts() {
        let control = NSView()
        let controlWidth = control.widthAnchor.constraint(equalToConstant: 260)
        NSLayoutConstraint.activate([controlWidth, control.heightAnchor.constraint(equalToConstant: 24)])
        let explanation = L10n.t("agent.access.explanation")
        let popup = NSPopUpButton()
        popup.addItems(withTitles: ["Off", "Read, create and change notes"])
        let popupRow = SettingsRow(title: "MCP", explanation: explanation, control: popup)
        let narrow = SettingsRow(title: L10n.t("agent.access"), explanation: explanation, control: control)
        let wide = SettingsRow(title: "Wide", explanation: String(repeating: "A long explanation with spaces. ", count: 5))
        let short = SettingsRow(title: "Short", explanation: L10n.t("storage.syncedNote"))
        let form = SettingsForm()
        form.card([narrow, popupRow, wide, short, SettingsRow(content: NSTextField(labelWithString: "Custom content"))])
        let content = form.makeContentView()
        let window = window(containing: content)
        defer { window.orderOut(nil) }
        print("Checking rows: \(L10n.currentLanguage), narrow / wide / hidden / changing controls")
        stable(content)
        let smallWidth = narrow.explanationLabel.preferredMaxLayoutWidth
        check(smallWidth > 0 && smallWidth < SettingsForm.explanationWidth, "wide control narrows explanation measurement")
        let smallHeight = narrow.explanationLabel.frame.height
        let requiredHeight = narrow.explanationLabel.cell!.cellSize(forBounds: NSRect(
            x: 0, y: 0, width: narrow.explanationLabel.bounds.width, height: 10_000
        )).height
        check(smallHeight >= requiredHeight - 1, "narrow explanation must show every line")
        let labelRect = narrow.explanationLabel.convert(narrow.explanationLabel.bounds, to: narrow)
        let controlRect = control.convert(control.bounds, to: narrow)
        check(labelRect.maxX <= controlRect.minX - SettingsForm.rowSpacing + 4,
              "explanation stays clear of its control")
        check(popupRow.explanationLabel.preferredMaxLayoutWidth < SettingsForm.explanationWidth,
              "the long MCP access option reduces the wrapping width")
        let popupWidth = popupRow.explanationLabel.preferredMaxLayoutWidth
        popup.removeAllItems()
        popup.addItems(withTitles: ["Off", "Read"])
        stable(content)
        check(popupRow.explanationLabel.preferredMaxLayoutWidth > popupWidth,
              "changing a control's intrinsic width remeasures the explanation")
        check(wide.explanationLabel.preferredMaxLayoutWidth == SettingsForm.explanationWidth, "wide rows keep the 280-point cap")

        controlWidth.constant = 100
        stable(content)
        check(narrow.explanationLabel.preferredMaxLayoutWidth > smallWidth, "measurement grows when control shrinks")
        check(narrow.explanationLabel.frame.height <= smallHeight, "more available width does not add lines")
        controlWidth.constant = 260
        stable(content)
        check(abs(narrow.explanationLabel.preferredMaxLayoutWidth - smallWidth) < 0.5, "measurement shrinks when control grows")
        short.explanationLabel.stringValue = String(repeating: explanation + " ", count: 4)
        stable(content)
        short.isHidden = true
        stable(content)
        short.isHidden = false
        stable(content)
        check(!short.explanationLabel.isHiddenOrHasHiddenAncestor, "explanation lays out after its row is revealed")
    }
}
