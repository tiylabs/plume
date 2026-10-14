<p align="center">
  <img src="Artifacts/plume-icon.png" alt="Plume" width="120">
</p>

<h1 align="center">Plume</h1>

<p align="center">
  在你的 macOS 上一键呼出的草稿本，Markdown 随记随查
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
  <img src="Artifacts/plume-hero.png" alt="Plume 浮在代码编辑器上方" width="760">
</p>

按 <kbd>⌃⌥Space</kbd>，笔记就浮到当前窗口上，写完再按一下就收起。
不限笔记数量，无需账号，无需订阅。

## 安装

```bash
brew install --cask tiylabs/tap/plume
```

或到 [Releases](https://github.com/tiylabs/plume/releases/latest) 下载 `.dmg`，把 Plume 拖进
Applications。发布版已签名并通过 Apple 公证。

## 功能

- **全局快捷键。** 打开上次写的那篇，光标停在原位。
- **实时渲染 Markdown。** 块级符号不显示，行内符号只在光标处显示。
- **一个面板搞定。** <kbd>⌘P</kbd> 切换笔记（模糊搜索 + 全文搜索），<kbd>⌘K</kbd> 打开操作。
- **普通文件。** 笔记就是你所选文件夹（默认 `~/Documents/Plume`）里的 `.md` 文件。
  外部修改会自动读入；发生冲突会另存一份，不会覆盖。
- **同步。** 在设置的 Storage 里选 iCloud Drive、你自己的同步工具管理的文件夹，或 Git 仓库。Git 同步使用你 Mac 上的 `git`，以及你自己的 SSH 密钥或已保存的凭据；每 5 分钟合并远端的更新，并提交、推送本地的修改。两边改了同一篇笔记时，笔记里会留下 Git 的冲突标记，菜单栏图标亮黄点，清除标记后自动恢复同步；同步失败时亮红点。
- **主题。** 主题就是放在 `~/Library/Application Support/Plume/Themes` 里的一个 CSS 文件。
- **连接你的 Agent。** 在设置的 Agent 页开启后，你自己的 AI Agent 可以通过 App 内附带的 `plume-agent`（本地 MCP 服务或命令行）搜索、读取笔记，并按你的写作偏好和模板新建笔记、局部修改笔记。默认关闭；可选只读；每次写入都有记录，可以恢复。
- **隐私。** 不申请任何系统权限，没有统计。联网请求只有两种：向 GitHub 检查更新（可在设置中关闭），以及 Git 同步（设置之前不会启用）。Agent 接入只通过本机的 Unix socket 通信，Plume 不会为此发起网络请求；Agent 读取到的内容如何处理，由 Agent 自己决定。

<kbd>⌘,</kbd> 打开设置，所有设置存在 `settings.json` 中，修改后立即生效。

## 从源码构建

只需 Command Line Tools，不需要 Xcode。

```bash
make test-all  # 运行全部测试
make dev       # 编译并启动独立的开发版 build/Plume Dev.app
make build     # 构建正式版 build/Plume.app
```

## 许可证

MIT，详见 [LICENSE](LICENSE) 和 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

Fork 自 [ColeMei/pane](https://github.com/ColeMei/pane)（MIT），分叉自提交 `526dda4`，此后独立开发。
与 Raycast Technologies 及上游项目无隶属或背书关系。
