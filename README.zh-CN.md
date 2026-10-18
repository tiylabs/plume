<p align="center">
  <img src="Artifacts/plume-icon.png" alt="Plume" width="120">
</p>

<h1 align="center">Plume</h1>

<p align="center">
  macOS 上一键呼出的 Markdown 草稿本。随手记录，文件自有，连接你的 Agent。
</p>

<p align="center">
  <a href="README.md">English</a> · 简体中文
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/tiylabs/plume?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/built_with-Swift-orange?logo=swift&style=flat-square" alt="Built with Swift">
  <img src="https://img.shields.io/badge/platform-macOS_14+-lightgrey?style=flat-square" alt="Platform: macOS 14+">
  <a href="https://github.com/tiylabs/plume/releases"><img src="https://img.shields.io/github/v/release/tiylabs/plume?style=flat-square" alt="Latest release"></a>
</p>

<p align="center">
  <img src="Artifacts/plume-hero.png" alt="Plume 产品示意图：暖金海岸上方的玻璃 Markdown 笔记与 MCP 设置面板" width="960">
</p>

按 <kbd>⌃⌥Space</kbd>，笔记就浮到当前窗口上，写完再按一下，回到手头的工作。
每篇笔记都是你自己文件夹里的普通 Markdown 文件。通过本地 MCP 或内附 CLI，
还可以让你自己的 AI Agent 查找笔记、协助写作。

不限笔记数量，无需账号，无需订阅。支持 macOS 14 及以上。

## 安装

```bash
brew install --cask tiylabs/tap/plume
```

或到 [Releases](https://github.com/tiylabs/plume/releases/latest) 下载 `.dmg`，把 Plume 拖进
Applications。发布版已签名并通过 Apple 公证。

## 开始记录

打开 Plume，呼出面板，直接写。笔记会自动保存。

| 快捷键 | 操作 |
| --- | --- |
| <kbd>⌃⌥Space</kbd> | 呼出或收起面板 |
| <kbd>⌘N</kbd> | 新建笔记 |
| <kbd>⌘P</kbd> | 查找笔记，支持标题模糊搜索与全文搜索 |
| <kbd>⌘K</kbd> | 打开操作：导出、固定笔记、桌面分配、最近删除等 |
| <kbd>⌘F</kbd> | 在当前笔记中查找 |
| <kbd>⌘,</kbd> | 打开设置 |

以上为默认快捷键。全局呼出键和操作快捷键可在设置中修改。

## 功能

- **接着上次写。** 一键回到上次的笔记和光标位置。面板可保持固定大小，也可随内容增长。
- **Markdown 即写即见。** 标题、列表、任务复选框、引用、代码块、链接和行内格式随输入排版。
  在 <kbd>⌘K</kbd> 中可拷贝 Markdown，或导出为独立 HTML 文件。
- **面板放在哪里，由你决定。** 在 <kbd>⌘K</kbd> 中选择「无」「当前桌面」或「全部桌面」，
  也会遵循 macOS Dock 的桌面分配。标题栏图钉可让面板持续置于其他应用上方。
- **文件属于你。** 每篇笔记都是所选文件夹（默认 `~/Documents/Plume`）里的 `.md` 文件。
  外部修改自动读入；与本地编辑冲突时，另存副本保留内容。删除的笔记可在你设定的保留期内从「最近删除」恢复。
- **按自己的方式同步。** 在设置 › 存储中选择 iCloud Drive、你自己的同步工具管理的文件夹，
  或 Git。Git 同步使用本机的 `git` 及你的 SSH 密钥或已保存的凭据，每 5 分钟提交本地修改、
  合并远端更新并推送。冲突以 Git 标记保留在笔记中，菜单栏黄点提示你处理，清除标记后继续同步；红点表示同步失败。
- **调整到顺手。** 支持浅色与深色外观、强调色、可调透明度、中英文界面，以及
  `~/Library/Application Support/Plume/Themes` 中的 CSS 主题。macOS 26 及以上支持 Liquid Glass。
- **和你的 Agent 一起写。** 通过本地 MCP 或内附 `plume-cli`，让你自己的 AI Agent
  按写作偏好与 Markdown 模板搜索、读取、新建和局部修改笔记。默认关闭，可分别选择只读或读写权限。

## 连接你的 Agent

1. 把 Plume 安装到「应用程序」，按 <kbd>⌘,</kbd> 打开设置 › MCP。
2. 将 **MCP 开关**设为**仅读取**或**读取和写入**。
3. 拷贝 **MCP 配置**，粘贴到 Agent 的本地 MCP 设置中（通常是 `mcpServers` 部分），
   然后重启 Agent。配置已包含小工具路径和连接凭据。
4. 编辑**写作偏好**和**模板**，告诉 Agent 你希望笔记怎么写。

例如，可以对 Agent 说：

> 把刚才的讨论整理进 Plume；有相关笔记就更新，没有就新建。

每次 Agent 写入都会列在**最近写入**中，可恢复的修改会显示**恢复…**按钮，用来还原修改前的内容。
Agent 不能删除笔记、修改设置、移动笔记文件夹或执行 Git。当面板拥有键盘焦点或有未保存的编辑时，
对当前笔记的修改会被拒绝。

使用 Shell 的 Agent 也可调用 MCP 配置中 `command` 指向的小工具，通过 `PLUME_CLI_TOKEN`
环境变量传入拷贝的凭据。若 Plume 安装在 `/Applications`，且已设置该环境变量：

```bash
/Applications/Plume.app/Contents/MacOS/plume-cli context
/Applications/Plume.app/Contents/MacOS/plume-cli notes search --query "项目"
```

移动 App 或轮转凭据后，请重新拷贝配置；更新 Plume 后，请重启 Agent。

## 隐私

不申请系统隐私权限，不收集统计信息。Plume 的联网请求只有 GitHub 更新检查，以及你启用的 Git 同步。
自动检查更新可在设置中关闭；Plume 不会自行下载或安装更新。

Agent 通过这台 Mac 上的本地 Unix socket 接入，不会增加 Plume 的网络请求。
如果你的 Agent 使用云端模型，它读取的笔记可能会发送到对应服务。

设置保存在 `~/Library/Application Support/Plume/settings.json` 中，修改后会实时重新加载。

## 从源码构建

需要 macOS、带 Swift 6+ 和 macOS 26 或更新 SDK 的 Command Line Tools，以及 Node.js 和 npm。
无需 Xcode 工程；Make 会通过 `npm ci` 安装编辑器依赖。

```bash
git clone https://github.com/tiylabs/plume.git
cd plume
make test-all  # 运行全部测试
make dev       # 编译并启动独立的开发版 build/Plume Dev.app
make build     # 构建正式版 build/Plume.app
```

开发版使用独立的设置和笔记，可与正式版同时运行。
仓库结构与验证命令见 [AGENTS.md](AGENTS.md)，也可运行 `make help`。
版本历史见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证

MIT，详见 [LICENSE](LICENSE) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

Fork 自 [ColeMei/pane](https://github.com/ColeMei/pane)（MIT），分叉自提交 `526dda4`，此后独立开发。
与 Raycast Technologies 及上游项目无隶属或背书关系。
