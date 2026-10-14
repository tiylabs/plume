# Agent 接入 · 首版验收清单

| 项 | 内容 |
|---|---|
| 对应方案 | [agent-integration-plan.md](agent-integration-plan.md) 第 13 节验收矩阵 |
| 阶段 0 记录 | [agent-integration-phase0.md](agent-integration-phase0.md) |
| 日期 | 2026-10-14 |

逐行对照第 13 节，记录每一行用什么方式验证、结果如何。“自动”指 `make test-all` 中的测试，引号内为测试名。PlumeKit 套件位于 `Tests/PlumeKitTests/Agent/`，WKWebView 套件为 `Editor/tests/webview/agent.test.js`，端到端检查为 `Scripts/smoke/agent-smoke.sh`。

## 1. 逐行对照

| # | 场景 | 状态 | 验证方式与结果 |
|---|---|---|---|
| 1 | 创建普通笔记 | 自动 | `AgentHandlerTests` “a created note is named and stored like a note made in the panel”：时间戳加中文 slug、`-2` 重名规则、末尾恰好一个换行、无标题内容回落、空白拒绝、超限拒绝 |
| 2 | 同一 create/append 请求重试或并发 | 自动 | “the same request ID never creates a second note, serially or concurrently”、“retrying an append never appends twice”、“different concurrent creates reserve distinct names and settle every record” |
| 3 | 同一 ID 换正文 | 自动 | “the same request ID with different text is refused and the original stands”；追加时同理（`REQUEST_ID_REUSED`） |
| 4 | 无效、多处匹配或重叠修改 | 自动 | `AgentDomainTests` change planner 套件：未匹配、多处匹配、重叠、大小写、一项失败则全部不应用；规划阶段失败，不会产生写入 |
| 5 | Agent 读取后用户输入，尚未自动保存 | 自动 | `AgentSessionTests` “typed but not yet saved: NOTE_BUSY; once saved, the old version conflicts; typing survives”（可控 scheduler） |
| 6 | Panel 聚焦或有未保存输入时修改当前笔记 | 自动 | “panel has the keyboard: NOTE_BUSY (editing), nothing changes”及第 5 行；Dev 包实测发现屏幕外 Panel 仍会报告 key window，现要求“已唤出且为 key” |
| 7 | Panel 显示中、未聚焦时修改当前笔记 | 自动 | 会话测试 “panel up but not focused: reloaded in place, toast, caret clamped, no second reload from the echo”；WKWebView `agent` 套件：同一文件重载后文本替换、光标夹到正文长度、⌘Z 无法回到被替换的文本 |
| 8 | Panel 收起时修改当前笔记 | 自动 + 现有行为 | “panel dismissed: buffer follows the disk and the news waits for the next summon”；下次 summon 时显示提示由现有的 `PanelController.showNews` 负责；操作记录为 `saved`，可在“最近写入”中恢复 |
| 9 | 检查通过后、写盘完成前用户开始输入 | 自动 | “typing that starts during the write”（注入写入延迟）：不发送 `loadNote`；用户输入进入 `-conflict-` 副本；目标保存 Agent 的修改；结果带 `user_edited_during_write` 警告 |
| 10 | 外部写入、删除或改名 | 自动 | “a changed file is a conflict; nothing is written, nothing is recreated”：外部写入返回 `VERSION_CONFLICT`，删除返回 `NOTE_NOT_FOUND` 且不重建；改名后旧 ref 指向的文件不存在，与删除走同一路径 |
| 11 | Git merge 与 API 同时写 | 自动 | `AgentGitGateTests`（真实临时 Git 仓库，持有 gate 时 commit 等待）；“while Git sync holds the working tree, a write answers NOTE_BUSY (syncing)” |
| 12 | iCloud evicted 文件 | 自动 + 手工 | `AgentAvailabilityTests`（通过 `VaultService` 的可用性接缝）：列表标记 `evicted`、搜索不读正文并计入 coverage、读取需 `download: true`、下载超时返回 `DOWNLOAD_TIMEOUT`、列表和搜索不触发下载。真实 iCloud 见第 2 节 M2 |
| 13 | 执行时切换/移动 Vault | 自动 + 手工 | “a vault switch invalidates refs and versions; an old create ID still returns its note”。切换 Vault 与 Move Notes 前会等待已接收的写入完成（`AppCoordinator`、`AgentAccessCoordinator`），这部分为 AppKit 流程，见 M5 |
| 14 | 修改进行中切换笔记、收起或退出 | 自动 + 手工 | “switching notes during the write: the write finishes, the new note is not reloaded”。退出时 `applicationShouldTerminate` 会等待写入完成；未完成的写入由 journal 在下次启动时结算。收起与退出见 M5 |
| 15 | 在准备后、文件保存后、journal 结算前崩溃 | 自动 | crash recovery 套件：在 `accepted`、`prepared`、`written` 三处注入中止，再由新 handler 恢复；目标被他人改动时为 `outcome_unknown`；journal 记录损坏时返回 `OUTCOME_UNKNOWN`，不会重新执行 |
| 16 | 断连、超时或取消 | 自动 | `AgentIPCTests` “… a lost app fails the waiters”、“a write that times out says it may have been saved and names its request”；`AgentMCPTests` “a cancelled call is forwarded and gets no response”；“a request cancelled before it is prepared writes nothing” |
| 17 | 权限撤销 | 自动 | “off, read-only and a revoked generation are refused per request”、“a revoke during a prepared write lets that write settle; the next request is refused”；清除记录会同时轮换凭据（“a damaged journal record …”中有断言） |
| 18 | 正式版/Dev、多个安装副本 | 自动 | `AgentIPCTests` “one owner per profile …”、实例不匹配返回 `APP_INSTANCE_MISMATCH`、release 与 dev 使用不同 socket；现有 `Scripts/test-dev-isolation.sh` |
| 19 | helper 经符号链接运行、在 bundle 外运行，或 App 被 translocate | 自动 | install location 套件；Dev 包中 `.build/` 下的产物会拒绝运行（退出码 2，已实测） |
| 20 | 未配置凭据的调用 | 自动 + smoke | “no credential: AUTH_FAILED at once, and the app is not launched”；smoke 中实测 App 未被拉起 |
| 21 | 启动时 Vault 缺失 | 自动 + 手工 | “… vault missing …”：1 秒内收到 `VAULT_UNAVAILABLE`；listener 先于 Vault 准备启动。chooser 交互见 M4 |
| 22 | 含 Git 冲突标记的笔记 | 自动 | 读取返回 `git_conflict_markers` 警告；搜索结果带 `has_conflict_markers`；写入时的格式警告同样会标出 |
| 23 | 写入速率超限 | 自动 | “over the write limit: RATE_LIMITED, not queued; a replay is free”；领域测试检查 `retry_after` |
| 24 | 路径穿越、符号链接、超长或畸形 JSON | 自动 | “read refuses what is not a note in the vault”、“list and search never read a link pointing outside the vault”、ref/path policy 测试、“strict frames …”、MCP 协议错误测试 |
| 25 | emoji、组合字符、CRLF | 自动 | change planner 的 grapheme 与 CRLF 用例；“a partial change keeps everything else byte for byte, CRLF included”（中间行保留 CRLF；最后一个换行按加载规则规范化） |
| 26 | 用户偏好、模板或范例含指令 | 自动 + 手工 | “instructions inside notes are data: they change no permission”；工具说明与格式指引都写明来源；第三方客户端见 M3 |
| 27 | 发布包 | 部分自动 + 手工 | Dev 包：helper 为 `x86_64 arm64`，`codesign --verify --deep --strict` 通过，smoke 通过。release workflow 已改为按架构构建并合并 helper，并检查架构与签名。Developer ID 签名、公证见 M1 |

另外，格式指引中的每条渲染声明都在 WKWebView `agent` 套件中有对应用例，共 23 条断言；为确认套件确实能失败，曾故意改坏两条期望，均被检出。

## 2. 需要 Jorben 手工完成

不阻塞首版完成，但发布前需要做。每项都只用 Dev 包或临时 Vault，除 M1 外不涉及正式版数据。

**M1 · Developer ID 签名与公证**
1. 在 release 流程（或本机带 `PLUME_SIGN_IDENTITY`）执行 `Scripts/build-app.sh --universal`。
2. `codesign -dv --verbose=4 Plume.app/Contents/MacOS/plume-agent`：确认 hardened runtime、时间戳，标识为 `com.tiylabs.plume.agent`。
3. 执行 `Scripts/notarize.sh`；`xcrun stapler validate Plume.app`、`spctl --assess --type execute Plume.app` 均通过。
4. 在一台干净的 Mac 上安装 DMG，通过 helper 路径运行 `plume-agent --version`，确认 Gatekeeper 不拦截。

**M2 · 真实 iCloud 驱逐**
1. Dev 包的 Vault 设为 `~/Library/Mobile Documents/com~apple~CloudDocs/Plume-dev`，写入一篇含关键字的笔记。
2. Finder 中对该文件选“移除下载项”。
3. `plume-agent notes list`：该笔记的 `availability` 为 `evicted`；`notes search --query <关键字>`：只能按标题找到，`bodies_not_searched ≥ 1`。
4. `notes read --ref …`：返回 `NOTE_NOT_AVAILABLE`；加 `--download` 后返回正文，期间 Panel 的保存不受影响。

**M3 · 第三方 Agent 客户端**
1. 设置 → Agent → 选“读取、新建和修改笔记” → MCP 配置旁点“拷贝”。
2. 粘贴到 Claude Code（`claude mcp add-json plume '<配置>'`，或写入 `.mcp.json`）、Claude Desktop、Codex 等常用客户端，然后重启客户端。
3. 让 Agent 执行“把刚才的讨论整理进 Plume；有相关笔记就更新，没有就新建”，确认依次调用了 context → search → read → modify/create，结果出现在“最近写入”中。
4. 在 Agent 的 Shell 沙箱中执行 CLI，确认被拦截时返回 `CONNECTION_BLOCKED` 和建议，而不是挂起。

**M4 · 启动时的 Vault chooser**
1. 退出 Plume Dev，把 Dev 的 Vault 文件夹改名。
2. 在终端用带凭据的 `plume-agent notes list` 拉起 App：命令应在 1 秒内返回 `VAULT_UNAVAILABLE`；屏幕上出现现有的 chooser。
3. 选择文件夹后再次执行命令，应正常返回。

**M5 · 写入进行中的 AppKit 流程**
1. 用 `Scripts/smoke/agent-smoke.sh` 的方式准备 Dev 包与临时 Vault。
2. 连续发起修改的同时执行：收起 Panel、⌘Q 退出、在设置中 Move Notes。
3. 预期：已接收的写入完成并在“最近写入”中显示为已保存，或在下次启动时被结算；Move Notes 不会把写入落到旧文件夹。

**M6 · 设置页外观**
按 [Settings 窗口设计规范](../Specs/settings-design-spec.md) 第 7 节，分别在浅色和深色下截图 Agent 页：控件右缘对齐、行高 ≥ 40；中英文都不截断。

## 3. 门禁结果

记录在提交说明与本文对应的提交中：`make test-all`、`make lint`（本机 SwiftLint 0.65.1，0 错误）、`Scripts/check-doc-refs.sh`、Dev 包 codesign 与 smoke。SwiftLint 0.63.2 的固定版本检查和 MCP SDK 实测都需要联网，等待授权（见阶段 0 记录第 7 节）。
