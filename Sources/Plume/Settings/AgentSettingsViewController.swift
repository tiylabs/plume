import AppKit
import PlumeKit

/// The MCP tab: whether a local AI agent may use the notes, how to connect one, the writing files
/// it reads, and what it has written.
///
/// Named for the protocol rather than for "agent": MCP is the word on the agent's own settings
/// screen, the thing a person is looking for when they come here to connect one. The type keeps
/// the Agent name, because the feature is agent access and MCP is one of its two ways in.
///
/// Laid out like every other tab (page → cards → rows). It scrolls, like Shortcuts, because the
/// recent-writes list grows; the window stays the size the other tabs agree on. With access off
/// the page is two rows tall, and stays at the top (`SettingsForm.embed(in:)`).
///
/// The credential is never shown on screen. It reaches the pasteboard only when the person presses
/// Copy, inside the configuration it belongs to, so a screenshot of this tab leaks nothing.
@MainActor
final class AgentSettingsViewController: NSViewController {

    private let agent: AgentAccessCoordinator
    /// Opens a note in the panel; the window belongs to the app, not to this tab.
    var onShowNote: ((String) -> Void)?

    private var scroll: NSScrollView!
    private var accessPopUp: NSPopUpButton!
    private var operationsByButton: [ObjectIdentifier: OperationRecord] = [:]

    private static let permissions: [AgentPermission] = [.off, .readOnly, .readWrite]

    init(agent: AgentAccessCoordinator) {
        self.agent = agent
        super.init(nibName: nil, bundle: nil)
        title = tr("settings.tab.mcp")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        scroll = SettingsForm.scrollView()
        view = scroll
        rebuild()
    }

    /// The journal or the switch changed. Cheap enough to rebuild: a few cards and at most a few
    /// dozen rows, on a window that is open rarely.
    func refresh() {
        guard isViewLoaded else { return }
        rebuild()
    }

    private func rebuild() {
        operationsByButton.removeAll()
        let form = SettingsForm()
        let permission = agent.permission

        // ---- access ------------------------------------------------------------------------
        accessPopUp = SettingsForm.popUp(
            [tr("agent.access.off"), tr("agent.access.readOnly"), tr("agent.access.readWrite")],
            target: self, action: #selector(accessChanged)
        )
        accessPopUp.selectItem(at: Self.permissions.firstIndex(of: permission) ?? 0)
        let status: String
        if permission == .off {
            status = tr("agent.status.off")
        } else if let problem = agent.serverProblem {
            status = tr("agent.status.unavailable", ["reason": problem])
        } else {
            status = tr("agent.status.ready")
        }
        // One card for everything about connecting: the switch and its state, then — once it is on —
        // the configuration to copy, the credential inside it, and the help. The shell helper's path
        // has no row of its own: it is the `command` in the MCP configuration, and the help says so.
        var rows: [NSView] = [
            SettingsRow(title: tr("agent.access"), explanation: tr("agent.access.explanation"), control: accessPopUp),
            SettingsRow(title: tr("agent.status"), control: SettingsForm.value(status)),
        ]
        var locationProblem: String?
        if permission != .off {
            switch agent.helperLocation {
            case .failure(let problem):
                locationProblem = problem == .translocated ? tr("agent.location.translocated") : tr("agent.location.readOnly")
            case .success:
                let copyConfig = SettingsForm.push(tr("agent.copy"), target: self, action: #selector(copyConfiguration(_:)))
                let copyToken = SettingsForm.push(tr("agent.copy"), target: self, action: #selector(copyCredential(_:)))
                let rotate = SettingsForm.push(tr("agent.rotate"), target: self, action: #selector(rotateCredential))
                rows += [
                    SettingsRow(title: tr("agent.mcp"), explanation: tr("agent.mcp.explanation"), control: copyConfig),
                    SettingsRow(title: tr("agent.credential"), explanation: tr("agent.credential.explanation"),
                                control: Self.pair(copyToken, rotate)),
                ]
            }
            rows.append(SettingsRow(
                title: tr("agent.help"),
                control: SettingsForm.push(tr("agent.help.show"), target: self, action: #selector(showHelp))
            ))
        }
        form.card(rows)
        if let locationProblem { form.footnote(locationProblem) }

        if permission != .off {
            // ---- guidelines: how the agent should write ----------------------------------------
            form.header(tr("agent.writing"))
            form.card([
                SettingsRow(
                    title: tr("agent.preferences"), explanation: tr("agent.preferences.explanation"),
                    control: SettingsForm.push(tr("agent.edit"), target: self, action: #selector(editPreferences))
                ),
                SettingsRow(
                    title: tr("agent.templates"), explanation: tr("agent.templates.explanation"),
                    control: SettingsForm.push(tr("agent.openFolder"), target: self, action: #selector(openTemplates))
                ),
            ])
        }

        // ---- recent writes -----------------------------------------------------------------
        let records = agent.recentOperations(limit: 20)
        if permission != .off || !records.isEmpty {
            form.header(tr("agent.recent"))
            if records.isEmpty {
                form.card([SettingsRow(title: tr("agent.recent.empty"))])
            } else {
                form.card(records.map(row(for:)))
                form.trailing(SettingsForm.push(tr("agent.clear"), target: self, action: #selector(clearHistory)))
            }
        }

        form.footnote(tr("agent.privacy"))
        form.embed(in: scroll)
    }

    private func row(for record: OperationRecord) -> NSView {
        let kind: String
        switch record.kind {
        case .create: kind = tr("agent.recent.create")
        case .modify: kind = tr("agent.recent.modify")
        case .restore: kind = tr("agent.recent.restore")
        }
        let state: String
        switch record.state {
        case .saved: state = tr("agent.recent.saved")
        case .rejected: state = tr("agent.recent.rejected")
        case .outcomeUnknown: state = tr("agent.recent.unknown")
        case .accepted, .prepared: state = tr("agent.recent.pending")
        }
        let title = (record.title?.isEmpty == false ? record.title : nil) ?? tr("agent.recent.untitled")
        let time = DateFormatter.localizedString(from: record.createdAt, dateStyle: .short, timeStyle: .short)
        let line = tr("agent.recent.line", ["time": time, "client": record.clientLabel ?? "—", "state": state])

        var buttons: [NSButton] = []
        if record.state == .saved, record.filename != nil {
            let show = SettingsForm.push(tr("agent.recent.show"), target: self, action: #selector(showNote(_:)))
            operationsByButton[ObjectIdentifier(show)] = record
            buttons.append(show)
        }
        if record.kind != .create, record.state == .saved, record.changed == true, !record.compacted {
            let restore = SettingsForm.push(tr("agent.recent.undo"), target: self, action: #selector(restoreOperation(_:)))
            operationsByButton[ObjectIdentifier(restore)] = record
            buttons.append(restore)
        }
        return SettingsRow(title: "\(kind) · \(title)", explanation: line, control: buttons.isEmpty ? nil : Self.pair(buttons))
    }

    private static func pair(_ views: NSView...) -> NSView { pair(views) }

    private static func pair(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    // MARK: - Actions

    @objc private func accessChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard Self.permissions.indices.contains(index) else { return }
        agent.setPermission(Self.permissions[index])
        rebuild()
    }

    @objc private func copyConfiguration(_ sender: NSButton) {
        guard let text = agent.mcpConfiguration() else { return }
        copy(text, sender)
    }

    @objc private func copyCredential(_ sender: NSButton) {
        guard let token = agent.access.token else { return }
        copy(token, sender)
    }

    /// Copies, and says so on the button for a moment — the one feedback that needs no new chrome.
    private func copy(_ text: String, _ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        let original = sender.title
        sender.title = tr("agent.copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak sender] in sender?.title = original }
    }

    @objc private func rotateCredential() {
        guard confirm(tr("agent.rotate.title"), tr("agent.rotate.detail"), tr("agent.rotate.button")) else { return }
        agent.rotateCredential()
        rebuild()
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = tr("agent.help")
        alert.informativeText = L10n.document("agent/help.md") ?? ""
        alert.addButton(withTitle: tr("agent.help.done"))
        _ = alert.runModal()
    }

    @objc private func editPreferences() {
        agent.writing.installExamplesIfFirstTime { L10n.document($0) }
        let url = agent.writing.preferencesURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data().write(to: url, options: [.withoutOverwriting])
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func openTemplates() {
        agent.writing.installExamplesIfFirstTime { L10n.document($0) }
        try? FileManager.default.createDirectory(at: agent.writing.templatesDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(agent.writing.templatesDirectory)
    }

    @objc private func showNote(_ sender: NSButton) {
        guard let filename = operationsByButton[ObjectIdentifier(sender)]?.filename else { return }
        onShowNote?(filename)
    }

    @objc private func restoreOperation(_ sender: NSButton) {
        guard let record = operationsByButton[ObjectIdentifier(sender)] else { return }
        let title = record.title ?? tr("agent.recent.untitled")
        guard confirm(tr("agent.restore.title"), tr("agent.restore.detail", ["title": title]), tr("agent.restore.button")) else { return }
        Task { @MainActor in
            if case .failure(let failure) = await agent.restore(record.operationID) {
                let alert = NSAlert()
                alert.messageText = tr("agent.restore.failed")
                alert.informativeText = failure.message
                alert.alertStyle = .warning
                _ = alert.runModal()
            }
            rebuild()
        }
    }

    @objc private func clearHistory() {
        guard confirm(tr("agent.clear.title"), tr("agent.clear.detail"), tr("agent.clear.button")) else { return }
        agent.clearHistory()
        rebuild()
    }

    private func confirm(_ title: String, _ detail: String, _ button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: tr("common.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
