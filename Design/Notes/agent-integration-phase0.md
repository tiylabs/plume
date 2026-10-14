# Agent 接入 · 阶段 0 记录

| 项 | 内容 |
|---|---|
| 对应方案 | [agent-integration-plan.md](agent-integration-plan.md)（v3）第 12 节阶段 0 |
| 日期 | 2026-10-14 |
| 测量环境 | macOS 27.0.1，Apple Silicon，APFS 本地卷，Swift 6.4（仅 CLI Tools 路径构建） |
| 结论代码 | `a40f06f`（实现）、`21db211`（打包） |

方案要求阶段 0 实测并记录几项技术选择。本文只记这些选择和依据，用户行为与写入契约以方案为准。

## 1. MCP：最小 stdio 实现，不引入 SDK

### 1.1 选择

`Sources/PlumeAgent/MCPServer.swift` 自行实现 tools-only 的 stdio 子集：按行分隔的 JSON-RPC 2.0，`initialize`、`notifications/initialized`、`ping`、`tools/list`、`tools/call`、`notifications/cancelled`，以及服务端发出的 `notifications/tools/list_changed`。协议版本协商 `2025-06-18`、`2025-03-26`、`2024-11-05`；`2025-06-18` 起返回 `structuredContent`，旧版本只返回文本内容。

### 1.2 对比

| 对比项（方案 3.4） | 官方 Swift MCP SDK `modelcontextprotocol/swift-sdk` 0.12.1（已实测） | 最小 stdio 实现（已采用） |
|---|---|---|
| stdio | `StdioTransport`；探针 server 的 `initialize` 与 `tools/list` 应答正确 | 支持，约 280 行，`AgentMCPTests` 覆盖 |
| 初始化 / 能力协商 | 完整；支持 `2025-11-25`、`2025-06-18`、`2025-03-26`、`2024-11-05` | 只声明 `tools.listChanged`；未知版本回落到最新支持版本 |
| tools schema | 由 SDK 类型生成 | `MCPToolCatalog` 手写 JSON Schema，与 `AgentTool` 同源 |
| 错误与取消 | 完整，处理 `notifications/cancelled`，取消后不再应答 | 业务失败为 `isError` 工具结果并保留错误码；协议错误 -32700/-32600/-32601/-32602；取消后不再应答 |
| macOS 14 | 最低 macOS 13；manifest 要求 `swift-tools-version:6.1`，高于本仓库的 6.0 | Foundation only，macOS 14 |
| 仅 CLI Tools、离线构建 | 首次 `swift package resolve` 联网 24 s，拉取 7 个包、34 MB 源码：swift-sdk、swift-log、swift-system、eventsource、swift-nio、swift-atomics、swift-collections（swift-nio 只被 SDK 自带的 conformance 可执行目标使用，但仍进入 `Package.resolved`）；manifest 还以 `branch: "main"` 声明 swift-docc-plugin（本次以 `exact: "0.12.1"` 解析时未进入 `Package.resolved`） | 无第三方依赖，离线可构建（已实测） |
| 二进制体积 | 一个只有一个工具的探针 server，universal release：9.3 MB，strip 后 4.2 MB；额外链接 `Network.framework` 与 `libc++` | 完整的 `plume-cli`（含 PlumeKit 的 IPC 客户端、CLI 与 MCP），universal release：6.7 MB，strip 后 3.6 MB |
| 许可证 | 处于 MIT → Apache-2.0 的过渡期，按贡献者分别适用；需新增 `THIRD_PARTY_NOTICES.md` 条目，并覆盖 swift-log、swift-system、eventsource 等传递依赖 | 无变化 |

测量（2026-10-14）：SDK 取 tag `0.12.1`（`a0ae212`）；构建工具链为 Xcode 的 Swift 6.2.3，`swift build -c release --arch arm64 --arch x86_64`，SDK 探针与 `plume-cli` 用同一命令、各自独立的 scratch 目录。本机切换到 CLI Tools 的 Swift 6.4（`DEVELOPER_DIR=/Library/Developer/CommandLineTools`）时，链接任何 manifest 都失败，包括本仓库自己的 `Package.swift`，属本机工具链安装问题，与 SDK 无关，因此两边都改用 Xcode 工具链比较。

结论不变：首版只需要 tools，自实现已满足需要，同时保持零依赖、离线可构建、体积更小，并且不必维护许可证过渡期的声明与 7 个传递依赖的版本。以后若需要 resources、prompts 或 HTTP transport（方案第 14 节），再重新评估 SDK。

## 2. helper 的路径与 profile 解析

实现：`AgentInstallLocation.resolve`，测试：`AgentIPCTests` 的 install location 套件。

1. 用 `_NSGetExecutablePath` 取内核记录的可执行文件路径（不用 `argv[0]`），再解析所有符号链接。
2. 真实路径必须是 `<X>.app/Contents/MacOS/plume-cli`，否则拒绝运行，退出码 2。`.build/` 下的产物，或者通过链接指向包外副本的文件，都会被拒绝。
3. 读取该 App 自己的 `Info.plist`：`com.tiylabs.plume` 且没有 `PlumeScratchBuild` 时为 release；`com.tiylabs.plume.dev`，或带 `PlumeScratchBuild` 的旧 scratch 包，为 dev；其他标识或缺失时拒绝运行，**不回落到 release**。
4. 不读取任何环境变量来切换 profile。
5. 实例标识为 App bundle 真实路径的 SHA-256 前缀。同一 profile 的两个安装副本因此可以区分，握手时不匹配会返回 `APP_INSTANCE_MISMATCH`。
6. 路径中含 `/AppTranslocation/`，或 App 所在卷只读（如挂载的 DMG）时，设置页不生成配置，并提示先移动 App。

## 3. IPC 运行目录

实现：`AgentRuntimeDirectory`、`AgentSocketServer`、`AgentOwnerLock`。

- 目录为 `confstr(_CS_DARWIN_USER_TEMP_DIR)` 下的 `plume-cli.<release|dev>/`，不读 `$TMPDIR`。本机 socket 路径为 79 字节，低于 `sun_path` 的 104 字节上限（测试中有断言）。
- 目录 `0700`，socket `0600`。`bind` 时临时把 umask 设为 `077`，socket 从创建起就不允许其他用户连接。两端都用 `lstat` 检查类型与 owner；连接接入后再用 `getpeereid` 检查对端 UID。
- `owner.lock` 由 `flock(LOCK_EX|LOCK_NB)` 持有，进程以任何方式退出时都由内核释放。只有拿到锁的进程才会清理陈旧 socket；路径上若是非 socket 文件，则保持原样并拒绝启动。`owner.json` 记录 owner 的 pid、实例和 bundle 路径，供 helper 判断是否属于其他安装副本。
- listener 在 Vault 准备之前启动，就绪状态由连接线程直接读取。即使主线程正处在 Vault chooser 的模态循环中，helper 也能在 1 秒内收到 `VAULT_UNAVAILABLE`（测试中有断言）。
- release 与 dev 的目录、锁和 socket 完全分开。

## 4. Git gate

实现：`VaultWriteGate`，接入 `GitSyncEngine` 与 `VaultIO.agentReplace/agentCreate`，测试：`AgentGitGateTests`、`AgentHandlerTests`。

- Git 一侧在完成合并、`commit`、`merge` 这三步持有 gate；`fetch` 和 `push` 只访问网络、不改工作树，不持有 gate，远端慢时不会卡住 API 写入。
- API 一侧在 `NSFileCoordinator` 区间内的 hash 比较与原子替换期间持有 gate。最多等待 5 秒，超时返回 `NOTE_BUSY`（`reason: syncing`），状态记为 `rejected`。
- Panel 自己的保存不经过 gate：Git 调度已有静默期和 cycle 前的 flush；给打字路径加锁会增加延迟。
- Git 合并留下的冲突标记，在读取和搜索结果中会以警告标出。

## 5. journal 的崩溃窗口与持久化

实现：`DurableFile`、`OperationJournal`、`NoteAccessHandler+Writes`。

写入顺序：`accepted`（落盘）→ 写入快照与 `prepared`（持久落盘）→ 写笔记文件 → `saved`（持久落盘）→ 返回成功。

- 持久化方式：先写临时文件，再执行 `F_FULLFSYNC`（不支持时退回 `fsync`，失败直接报错）、`rename`，最后对目录执行 `fsync`。**实测**（2 KiB，50 次）：中位数 3.99 ms，p95 4.19 ms；不做同步的原子写为 0.09 ms。每次写入要持久化 2–4 次，增加约 10–15 ms，可以接受。该写入在独立队列执行，不阻塞主线程。
- 笔记文件本身沿用 `Data.write(.atomic)`，不做 full sync。断电后若笔记回到修改前、但 journal 已是 `prepared`，下次启动会按记录完成写入；文件已是修改后内容则只补记 `saved`。
- 每个窗口都有进程中止注入测试：`accepted`、`prepared`、`written` 之后中止，再由新的 handler 恢复。结果分别为：未写入时记为 `rejected`；创建写到预留的同一路径；修改只应用一次；目标已被他人改动时记为 `outcome_unknown`，不覆盖文件。
- journal 记录损坏时，返回 `OUTCOME_UNKNOWN`，**不视为“从未收到”**，否则同一请求会被执行两次。
- 保证范围：本地 APFS 上的进程崩溃与断电。网络卷、FAT 等文件系统，以及硬件故障，不在保证之内。

## 6. 其他探针

| 探针 | 方法 | 结果 |
|---|---|---|
| Agent 沙箱拦截 socket | `sandbox-exec -p '(version 1)(allow default)(deny network*)'` 下连接存活的 Unix socket | `connect` 返回 `EPERM`；helper 将 `EPERM`/`EACCES` 映射为 `CONNECTION_BLOCKED` |
| 后台延迟（App Nap） | helper 用 `open -g` 拉起 Dev 包，Panel 未显示，App 为 accessory | 拉起加 `tools/list` 0.29–0.40 s；创建 20 ms、搜索 4 ms、读取 3 ms、修改 20 ms。请求期间都在 `beginActivity(.userInitiated)` 内 |
| 未配置凭据 | 不设置 `PLUME_CLI_TOKEN` 调用 CLI | 退出码 1，返回 `AUTH_FAILED`，App 未被拉起 |
| 停放的 Panel 仍是 key window | smoke 首次运行时，后台启动的 App 对屏幕外 Panel 报告 `isKeyWindow == true` | “用户在编辑”改为同时要求 Panel 已唤出且为 key window |
| 启动时的就绪状态 | 在 `prepare()` 之前就报告“Vault 不可用” | smoke 实测：Vault 正常时，helper 在恢复完成前会收到不可重试的 `VAULT_UNAVAILABLE`。现改为只在 chooser 实际弹出时报告，选定文件夹后恢复；其余时间为可重试的 `APP_NOT_READY` |
| Dev 包 | `Scripts/build-app.sh --debug` | helper 为 `x86_64 arm64`，标识 `com.tiylabs.plume.dev.cli`，`codesign --verify --deep --strict` 通过 |

端到端 smoke 脚本：`Scripts/smoke/agent-smoke.sh`。脚本会备份并恢复 `Plume (Debug)` 支持目录，只使用临时 Vault。

## 7. 补测记录

- MCP SDK 实测：已于 2026-10-14 完成，见第 1.2 节。
- SwiftLint 0.63.2（CI 固定版本）：`swiftlint lint --quiet` 为 0 错误、45 条警告；按 CI 规则，警告不导致失败。`NoteSession.swift` 仍为 727 行，与基线 `99fd7af` 相同，低于 `file_length` 错误阈值 800。
