<p align="center">
  <img src="Artifacts/plume-icon.png" alt="Plume app icon" width="120">
</p>

<h1 align="center">Plume</h1>

<p align="center">
  A floating Markdown notepad for macOS. Capture a thought, keep your files, connect your agent.
</p>

<p align="center">
  English · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/tiylabs/plume?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/built_with-Swift-orange?logo=swift&style=flat-square" alt="Built with Swift">
  <img src="https://img.shields.io/badge/platform-macOS_14+-lightgrey?style=flat-square" alt="Platform: macOS 14+">
  <a href="https://github.com/tiylabs/plume/releases"><img src="https://img.shields.io/github/v/release/tiylabs/plume?style=flat-square" alt="Latest release"></a>
</p>

<p align="center">
  <img src="Artifacts/plume-hero.png" alt="Plume product illustration: a glass Markdown note beside MCP settings, above a sunlit coast" width="960">
</p>

Press <kbd>⌃⌥Space</kbd> to bring a floating note over your current app, write, and press it again
to get back to work. Notes are plain Markdown files in a folder you own. Connect your own AI agent
through local MCP or the bundled CLI to find notes and help write them.

Unlimited notes, no account, no subscription. Requires macOS 14 or later.

## Install

```bash
brew install --cask tiylabs/tap/plume
```

Or download the `.dmg` from the [latest release](https://github.com/tiylabs/plume/releases/latest)
and drag `Plume.app` into `Applications`. Releases are signed and notarized by Apple.

## Start writing

Open Plume, summon the panel, and write. It saves automatically.

| Shortcut | Action |
| --- | --- |
| <kbd>⌃⌥Space</kbd> | Summon or dismiss the panel |
| <kbd>⌘N</kbd> | Start a new note |
| <kbd>⌘P</kbd> | Find notes with fuzzy title and full-text search |
| <kbd>⌘K</kbd> | Open actions: export, pin, desktop assignment, Recently Deleted, and more |
| <kbd>⌘F</kbd> | Find text in the current note |
| <kbd>⌘,</kbd> | Open Settings |

These are the default shortcuts. Change the global hotkey and action shortcuts in Settings.

## Features

- **Pick up where you left off.** The global hotkey brings back your last note and caret position.
  Keep the panel at a fixed size or let it grow with the note.
- **Live Markdown.** Headings, lists, task checkboxes, quotes, code blocks, links, and inline
  formatting render as you type. Copy Markdown or export a self-contained HTML file from <kbd>⌘K</kbd>.
- **Your desktop, your choice.** Use <kbd>⌘K</kbd> to choose None, This Desktop, or All Desktops.
  Plume also respects macOS Dock assignments. The title-bar thumbtack keeps the panel above other apps.
- **Files you own.** Each note is a `.md` file in a folder you choose (`~/Documents/Plume` by default).
  External edits appear automatically; conflicting local edits are kept in a separate file.
  Deleted notes can be recovered from Recently Deleted during the retention period you choose.
- **Sync your way.** Choose iCloud Drive, a folder managed by your own sync tool, or Git under
  Settings › Storage. Git sync uses your Mac's `git` and your SSH keys or saved credentials to commit
  local changes, merge remote changes, and push every 5 minutes. Conflicts stay in the note as Git
  markers; a yellow menu bar dot asks you to resolve them before syncing continues. A red dot means
  a sync failed.
- **Make it yours.** Light and dark appearances, accent colors, adjustable transparency, English
  and Simplified Chinese, and CSS themes in `~/Library/Application Support/Plume/Themes`.
  Liquid Glass is available on macOS 26 and later.
- **Work with your agent.** Local MCP and the bundled `plume-cli` let your own AI agent search,
  read, create, and partly edit notes using your writing preferences and Markdown templates.
  Access is off by default, with separate read-only and read/write modes.

## Connect your agent

1. Install Plume in `Applications`, then open Settings › MCP with <kbd>⌘,</kbd>.
2. Set **MCP access** to **Read only** or **Read and write**.
3. Copy **MCP configuration** into your agent's local MCP settings (usually its `mcpServers`
   section), then restart the agent. The configuration includes the helper path and credential.
4. Edit **Writing preferences** and **Templates** to tell the agent how you like notes written.

For example, ask your agent:

> Summarize our discussion in Plume. Update a related note if one exists; otherwise create a new one.

Every agent write appears under **Recent writes**. Eligible edits have a **Restore…** action to
recover the earlier text. The agent cannot delete notes, change settings, move the notes folder,
or run Git. Changes to the open note are refused while the panel has keyboard focus or unsaved edits.

For agents that use shell commands, use the helper at the `command` path in the MCP configuration
and pass the copied credential through `PLUME_CLI_TOKEN`. With Plume installed in `/Applications`
and that environment variable set:

```bash
/Applications/Plume.app/Contents/MacOS/plume-cli context
/Applications/Plume.app/Contents/MacOS/plume-cli notes search --query "project"
```

If you move the app or rotate the credential, copy the configuration again. Restart your agent
after updating Plume.

## Privacy

No system privacy permissions requested, no telemetry. Plume's network requests are GitHub update
checks and Git sync if you enable it. Automatic update checks can be turned off in Settings;
Plume does not download or install updates itself.

Agent access uses a local Unix socket on your Mac and adds no network requests from Plume.
If your agent uses a cloud model, the notes it reads may be sent to that service.

Settings are stored in `~/Library/Application Support/Plume/settings.json` and reloaded live.

## Build from source

Requires macOS, Command Line Tools with Swift 6+ and the macOS 26 SDK or newer, and Node.js with npm.
No Xcode project is needed; Make installs the editor dependencies with `npm ci`.

```bash
git clone https://github.com/tiylabs/plume.git
cd plume
make test-all  # every test suite
make dev       # rebuild and launch the isolated build/Plume Dev.app
make build     # release build of build/Plume.app
```

The Dev app uses separate settings and notes, so it can run alongside the release app.
See [AGENTS.md](AGENTS.md) for the repository layout and verification commands, or run `make help`.
See [CHANGELOG.md](CHANGELOG.md) for release history.

## License

MIT. See [LICENSE](LICENSE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Forked from [ColeMei/pane](https://github.com/ColeMei/pane) (MIT) at commit `526dda4` and
developed independently since. Not affiliated with or endorsed by Raycast Technologies or the
upstream project.
