# Plume 架构优化实施方案

| 项 | 内容 |
|---|---|
| 状态 | 阶段 0–4 已实施；待做：dev 构建日常使用 ≥ 3 天，然后合入 |
| 日期 | 2026-10-13 |
| 基线提交 | `2a1c8ff`（master） |
| 范围 | 模块划分、项目架构、目录结构、命名规范、工程护栏 |
| 不在范围 | 新功能、UI 视觉改动、Git 历史重写、多面板（multi-panel）实现 |

> 本文件位于 `Design/Notes/`，随仓库提交（原先放在被 `.gitignore` 忽略的 `docs/` 下，2026-10-13 移入）。文中为讨论规则会引用 `decision N` 这类写法，所以 `Scripts/check-doc-refs.sh` 把它排除在统计之外。

### 修订记录

| 版本 | 日期 | 变更 |
|---|---|---|
| v1 | 2026-10-13 | 初稿 |
| v2 | 2026-10-13 | 纳入 4 项决定（见 0.4）：删除 5 张未用截图；设计素材保留并归位到 `Design/`；开发版笔记库默认改为 `~/Documents/Plume-dev`；未公开文档引用按方案 B 治理（新增 PR 0.6 计数棘轮，并新增 10.1 节）。阶段 5 的条目改名为 L1–L6，避免与第 5 节的小节号重名。按实测更正引用统计（760 处，v1 写的是 471 处），补充阶段 1 漏掉的路径依赖（`test-dev-isolation.sh` 的 `swiftc` 通配符、`make-icons.swift` 的输入目录） |

---

## 0. 背景与目标

### 0.1 现状问题（来自架构 review）

1. **上帝对象**：`Sources/Plume/PlumeController.swift`（2092 行）同时承担窗口、几何、Space、hover、笔记会话状态机、历史、桥接分发等职责。最复杂的写入/改名/冲突逻辑由 7 个布尔标志维持，而且处在不能单测的 AppKit target 中。`AppDelegate.swift`（683 行）既是组装入口，也负责多项业务。
2. **模块边界没有按设计执行**：`Package.swift` 规定"纯 Foundation 的放 PlumeKit"，但 `VaultService`、`StateStore`/`SettingsStore`、`UpdateChecker`，以及 Git 同步的调度逻辑都留在 App target。
3. **桥接协议靠手工两端同步**：31 种入站消息（`PlumeMessage` ↔ `OutboundMessage`）、23 个出站方法（`editor.call("…")` ↔ `host`）都没有编译期或测试期的一致性检查。
4. **命名**：Pane→Plume 改名时做了全局替换，产品名渗进了领域模型（`PlumeState`、`plumeHeight`、`"shortcutGroup.plume": "The panel"`）。另外有多个文件名与其中的类型不一致，"Sync" 一词多义，同一概念存在两套叫法。
5. **目录**：`PlumeKit` 28 个文件平铺；测试放在 `Sources/` 下；`Scripts/` 里混放 `Info.plist` 和 `.icns`；5 个几乎一样的 WKWebView 测试脚本；22 MB 设计素材平铺在 `Design/Material`，没有说明哪些是定稿、哪些是探索稿；`artifacts/` 里有 5 张 README 没用到的截图；开发版笔记库放在构建目录 `build/Plume-scratch`；`Editor/src` 只有一部分分了子目录。
6. **工程护栏缺口**：CI 没跑 i18n 套件（`test-all.sh` 里有，CI 的测试列表漏了）；SwiftLint 没进 CI，而且关闭了长度类规则；`tsconfig.json` 不覆盖 `tests/unit/*.ts`。
7. **注释引用未公开文档**：受版本控制的文件里共有 **760 处**引用，分布在 106 个文件中。其中 `decision N` 708 处（约 138 个编号），`design frame Xy` 51 处，`LAB.md` 1 处。这些文档不在仓库里，本机原本也没有 `docs/` 目录。其中 `Themes/*.css` 会被复制到用户的主题目录，`packaging/plume.rb` 会进入 Homebrew tap，这两处的引用对用户和外部维护者都是死链。

### 0.2 目标

- **G1 可测**：笔记会话状态机、持久化、Vault 服务、Git 调度、桥接解码全部进入 PlumeKit，可以单元测试。
- **G2 职责单一**：任何 Swift 文件 ≤ 800 行，`main.ts` ≤ 300 行；每个类型只有一个变化原因。
- **G3 结构可导航**：目录按领域分组，文件名等于类型名，新人从目录树就能找到代码。
- **G4 命名一致**：领域词汇统一（Panel / Note / Vault / Session），产品名只出现在 App 级标识上。
- **G5 契约受检**：桥接、持久化格式、主题 CSS 接口都有自动化检查，改错时测试会失败。

### 0.3 非目标

- 不改变任何用户可见行为（文案、快捷键、动画、文件格式）。
- 不重写 Git 历史（`.git` 45 MB，靠后续不再提交大文件控制增长）。
- 不引入第三方依赖（Swift 侧保持零依赖；Editor 侧不新增运行时依赖）。
- 不实现多面板，但拆分后的结构不能阻碍将来实现它。

### 0.4 已确认事项（2026-10-13）

| # | 事项 | 决定 | 落实位置 |
|---|---|---|---|
| 1 | README 没用到的截图 | **删除**：`plume-actions.png`、`plume-dark.png`、`plume-settings.png`、`plume-switcher.png`、`ScreenShot_2026-10-11_025745_836@2x.png` | PR 1.7 |
| 2 | `Design/Material` 设计素材 | **保留在仓库**，按"定稿 / 探索稿 / 规格 / 笔记"归位，并补 `Design/README.md` | PR 1.7 |
| 3 | 开发版笔记库位置 | 默认改为 **`~/Documents/Plume-dev`**，不再放在 `build/` 下 | PR 1.8（从可选改为必做） |
| 4 | 未公开文档的引用 | **方案 B**：不公开原文；禁止新增引用（计数棘轮）；存量改写为自洽的说明，最终清零 | PR 0.6、各阶段顺手改写、长期项 L2 收尾（10.1） |

---

## 1. 实施原则

1. **行为不变**：本方案中每个 PR 都是重构。看到 bug 只记录，单独提 `fix` PR，不在重构 PR 里顺手修。
2. **移动与修改分离**：`git mv` 单独一个提交，不改内容，保证 `git log --follow` 和 rename 检测（相似度 >50%）有效。内容修改放在后续提交。
3. **先护栏，后动刀**：阶段 0 先补齐 CI 和兼容性快照测试，之后每一步都有自动化兜底。
4. **小步可回滚**：每个 PR 单一意图，可以独立 `git revert`；单个 PR diff 控制在约 800 行以内，纯 `git mv` 不计。
5. **先引入接缝，再搬迁，最后补测试**：对于无法先写测试的 AppKit 代码，先在原地引入抽象（输出协议、调度器），保持行为不变；再整体搬到 PlumeKit；然后补单测。搬迁 PR 依靠 smoke t1 和手工清单兜底。
6. **兼容面冻结**：第 2 节列出的对外接口，本方案中一律不改名；确实要改，必须走"迁移 + 快照更新 + CHANGELOG"流程。
7. **提交规范**：沿用 `Scripts/check-commit-msg.sh` 的约定式提交，例如 `refactor(kit): ♻️ Group PlumeKit sources by domain`。PR 目标分支为 `master`。
8. **注释自洽**：注释只写仓库里能看到的理由，不引用 `decision N`、`frame Xy`、`LAB.md` 这类外部编号或文件（附录 A.8）。搬迁代码时先原样搬，再用单独的提交改写搬过去的注释，这样不违反原则 2。

---

## 2. 兼容性红线（冻结清单）

下面这些名字已经写进用户磁盘、用户主题或外部系统，**本方案中保持字节级不变**：

| 类别 | 冻结内容 | 原因 | 保护手段（阶段 0 建立） |
|---|---|---|---|
| `settings.json` | 所有键名；`shortcuts` 字典的 action key，**包括 `pinPlume`** | 用户可以手工编辑；降级时要能读回 | Settings 编解码快照测试 |
| `state.json` | 所有键名，**包括 `plumes`** | 存放置顶、光标、窗口 frame，丢失后无法重建 | AppState 夹具解码测试 |
| 主题 CSS 接口 | `.cm-*`、`.plume-*` 装饰类（如 `.plume-line-h1`、`.plume-task--done`）、`.plume` / `.plume__*` chrome 类、`#plume*` id、`data-plume-*` 属性、CSS 自定义属性（`--text-size`、`--accent-*` 等） | 用户主题位于 `~/Library/Application Support/Plume/Themes`，Plume 无法替用户修改 | 主题选择器存在性检查 |
| 桥接命名空间 | `window.plumeHost`、`messageHandlers.plume` | 两端约定；属于产品命名空间，不是领域名词 | 桥接契约测试（阶段 3） |
| App 标识 | bundle id `com.tiylabs.plume(.dev)`、Application Support 目录名（`Plume`、`Plume (Debug)`）、Info.plist 键 `PlumeScratchBuild` | 改动后用户数据（或开发版设置）就"消失"了 | CI 现有 bundle 校验 + `test-dev-isolation.sh` |
| 笔记文件 | 文件名格式、尾换行规范化、冲突副本命名 | 用户的数据本身 | 现有 PlumeKit 测试 |

> 判断规则：`plume` / `Plume` 用作**产品命名空间前缀**（CSS 类前缀、bundle id、模块名）时保留；用作 **"面板"这个领域名词**时才改。

---

## 3. 阶段总览

```
阶段0 护栏 ──▶ 阶段1 目录整理 ──▶ 阶段2 命名统一 ──▶ 阶段3 边界纠正 ──▶ 阶段4 拆分上帝对象
  (1-2d)          (2-3d)             (2-4d)            (4-6d)              (8-12d)
                                                          └──────────▶ 阶段5 长期项（按需，可并行）
```

| 阶段 | 目标 | 主要产出 | 风险 | 预估 |
|---|---|---|---|---|
| 0 护栏与基线 | 后续每一步都有自动化兜底 | CI 单入口、lint 棘轮、兼容性快照、文档引用棘轮、基线度量 | 低 | 1–2 人日 |
| 1 目录与仓库整理 | 结构可导航；基本只移动，不改逻辑 | 子目录分组、`Tests/`、`App/`、`test-web.sh`、设计素材归位、删除未用截图、开发版笔记库迁到 `~/Documents/Plume-dev` | 低 | 2–3 人日 |
| 2 命名统一 | 领域词汇一致，文件名等于类型名 | Panel 改名、文件拆分、概念改名、命名规范 | 低–中 | 2–4 人日 |
| 3 模块边界纠正 | 纯逻辑进入 PlumeKit；桥接受检 | Persistence/Vault/Release/GitSync 下沉，Scheduler，桥接契约 | 中 | 4–6 人日 |
| 4 拆分上帝对象 | 职责单一，会话状态机可测 | `NoteSession`、`EditorBridgeRouter`、`PanelController`、`AppCoordinator`、Editor 拆分 | 中–高 | 8–12 人日 |
| 5 长期项 | 进一步降低维护成本 | swift-testing、决策记录治理、并发现代化等 | 视项而定 | 按需 |

预估按一个熟悉代码的人计算，包含 review 与回归时间。

---

## 4. 通用验收标准（每个 PR 都适用）

| # | 标准 | 检查方式 |
|---|---|---|
| D1 | 全部测试通过 | `make test-all` 本地通过 + CI 通过 |
| D2 | 断言数不减少 | 各套件断言数 ≥ 附录 C 的基线；减少必须在 PR 描述中逐条说明理由 |
| D3 | 产物有效 | CI "Verify the bundle" 步骤通过；纯移动类 PR 额外比对 bundle 资源清单（见 1.4） |
| D4 | 兼容面不变 | 阶段 0 建立的快照测试不需要更新即可通过；需要更新就说明触碰了红线，必须走迁移流程 |
| D5 | 运行时回归 | 涉及运行时代码的 PR（标 🧪）：`make dev` 后执行 `swift Scripts/smoke/t1.swift` 全部通过，并完成附录 D 手工清单中相关的条目 |
| D6 | 提交规范 | `Scripts/check-commit-msg.sh` 通过；`git mv` 提交与内容修改提交分开 |
| D7 | lint | SwiftLint（阶段 0 后进入 CI）和 `tsc` 无新增告警 |
| D8 | 文档引用不增加 | `Scripts/check-doc-refs.sh`（PR 0.6）通过；引用数下降的 PR 同时下调基线文件中的数字 |

---

## 5. 阶段 0：护栏与基线

### 5.1 目标
在动任何结构之前，把"改坏了能被发现"这件事落实到 CI 上，并记录基线，供后续比对。

### 5.2 策略
只加检查，不改产品代码。所有新增检查**在当前代码上必须是绿的**，阈值按当前实测值设定，后续逐步收紧（棘轮）。

### 5.3 执行细节

#### PR 0.1 CI 单一测试入口
- 问题：`.github/workflows/ci.yml` 的 "Test the editor" 和 `release.yml` 第 60–64 行各自维护一份测试列表，**都漏了 `Scripts/test-i18n.sh`**，与 `Scripts/test-all.sh` 已经不一致。
- 做法：
  1. 两个 workflow 中的 "Typecheck / Test PlumeKit / Build the editor bundle / Test the editor" 合并为一步 `Scripts/test-all.sh`（它内部已经包含 typecheck、构建 bundle 和全部套件）。
  2. `test-all.sh` 失败时返回非零码（现状已满足），CI 以它为准。
  3. 在 `test-all.sh` 顶部注释写明：**新增套件只登记在这里**。
  4. 这个 PR 本来就要改 `ci.yml`，顺手把其中 4 处 `decision 9` / `decision 99` 改写成自洽说明（规则见附录 A.8）。
- 验收：CI 日志中出现 "i18n" 步骤；`grep -c 'test-.*\.sh' .github/workflows/*.yml` 只剩 `test-all.sh` 和 `test-dev-isolation.sh`。

#### PR 0.2 SwiftLint 进入 CI，长度规则改为棘轮
- 现状：CI 不跑 SwiftLint，本机也没装；`.swiftlint.yml` 关闭了 `file_length`、`type_body_length`、`function_body_length`、`cyclomatic_complexity`。
- 做法：
  1. CI 的 macOS job 增加 `brew install swiftlint && swiftlint lint --strict --quiet`，或者使用固定版本的二进制以免规则漂移。
  2. 重新启用 `file_length`、`type_body_length`、`function_body_length`，**error 阈值 = 当前 `swiftlint` 实测最大值 × 1.05**（以工具输出为准，因为 `type_body_length` 不计注释行），warning 阈值设为目标值：

     | 规则 | warning（目标） | error（阶段 0） | error（阶段 4 结束） |
     |---|---|---|---|
     | file_length | 600 | 实测 ×1.05（约 2200） | 1000 |
     | type_body_length | 400 | 实测 ×1.05 | 700 |
     | function_body_length | 80 | 实测 ×1.05 | 150 |

  3. `included` 中加入 `Tests`（为阶段 1 做准备，目录不存在时会被忽略）。
- 验收：CI 中 lint 步骤为绿；`.swiftlint.yml` 中每条规则注释写明"计划在阶段 X 收紧到 Y"。

#### PR 0.3 Editor 单测纳入 typecheck
- 现状：`Editor/tsconfig.json` 的 `include` 只有 `src/**/*.ts`。`tests/unit/*.ts` 只经过 esbuild 打包，esbuild 只剥离类型，**不做类型检查**。
- 做法：新增 `Editor/tsconfig.test.json`（`extends` 主配置，`include` 加上 `tests/unit/**/*.ts`），`package.json` 中 `typecheck` 改为 `tsc --noEmit && tsc --noEmit -p tsconfig.test.json`。
- 验收：在测试文件里故意写一个类型错误，`make lint` 会失败；正常情况下通过。

#### PR 0.4 兼容性快照测试 🧪
新增 4 类检查，用来保护第 2 节的红线：

1. **Settings 快照**（`SettingsTests`）：
   - `Settings()` 用 `.sortedKeys` 编码后与夹具 `Fixtures/settings-default.json`（位置见本 PR 末尾）逐字节比对。测试可执行文件不是 .app，`BuildProfile.current` 会解析为 `.release`，所以夹具对应的是发布版默认值；
   - 解码一份 v0.4.x 真实形态的夹具（包含 `shortcuts.pinPlume`、未知键），断言各字段值正确、未知键保留。
2. **AppState 夹具**（`StateTests`）：解码包含 `plumes`、`notes`、`vaultEverCreated` 的夹具；再编码，断言输出仍使用 `plumes` 键。
3. **主题选择器存在性**（新增 node 脚本 `Editor/tests/theme-contract.mjs`，接入 `test-all.sh`）：提取 `Themes/*.css` 中出现的全部 `.plume-*` / `.cm-*` 类名，断言每个类名都出现在 `Editor/src` 中（作为字符串字面量或 CSS 选择器）；再维护一份 `Editor/tests/theme-api.txt` 公开类名清单，与源码提取结果比对，防止类名被意外删除。
4. **桥接名称快照**（过渡用，阶段 3 由契约测试替代）：把 31 个入站 `type`、23 个 `host` 方法名写入 `Editor/tests/bridge-names.txt`，由脚本从 `main.ts` 和 `EditorWebView.swift` 提取后比对。

- 夹具目录：阶段 0 先放 `Sources/PlumeKitTests/Fixtures/`，阶段 1 随测试目录一起迁移。由于测试是可执行 target，夹具通过 `#filePath` 定位源码目录读取，不走 SwiftPM resources。
- 验收：4 类检查都接入 `test-all.sh`；手工把 `plumes` 改成 `panels` 后测试变红，还原后变绿。

#### PR 0.5 记录基线
- 跑一次 `make test-all`，把每个套件的断言数和耗时填入附录 C；
- 跑一次 smoke t1，记录通过的条目清单；
- 记录附录 C 中的静态度量（行数、文件数）。
- 验收：附录 C 不再有"待填"项。

#### PR 0.6 文档引用棘轮（方案 B 的护栏）
- 目标：从这个 PR 起，**引用未公开文档的数量只减不增**。存量按 10.1 的节奏改写，最终清零。
- 新增 `Scripts/check-doc-refs.sh`：
  - 匹配规则：`[Dd]ecisions? [0-9]+|[Ff]rames? [0-9]+[a-z]\b|LAB\.md|BRIEF\.md`。
  - 统计范围：`git ls-files` 列出的全部文本文件，排除 `.gitignore`。`.gitignore` 里的那条注释是在解释这些文档为什么只留在本地，属于合理提及。
  - 基线写在 `Scripts/doc-refs.baseline` 里，只有一个数字，初始值为 **760**（2026-10-13 在 `2a1c8ff` 上实测）。
  - 判定方式为严格棘轮：
    - 实际数 > 基线：失败，列出 `git diff origin/master...HEAD` 中新增的命中行；
    - 实际数 < 基线：也失败，提示"请把基线下调到 N"，让每次减少都被固化下来；
    - 相等：通过。
  - 接入 `make lint` 和 CI 的 macOS job。
- 为什么不直接检查 diff 里的新增行：阶段 4 会把代码原样搬到新文件，按 diff 检查会把搬过去的旧引用全部算成新增，逼着在搬迁提交里改注释，违反原则 2。计数棘轮只看总数，搬迁不受影响。
- 验收：在任意源文件里加一行 `// decision 1` 后 CI 变红，删掉后变绿；脚本输出与基线文件一致。基线以合入时实测为准：如果 PR 0.1 先合入，应为 756。

### 5.4 阶段 0 验收
- [ ] CI 执行 `test-all.sh` 的全部步骤（含 i18n），以及 4 类兼容性检查
- [ ] SwiftLint 在 CI 中为绿，长度规则已启用
- [ ] `check-doc-refs.sh` 已接入 CI，基线为 760 减去 PR 0.1 改写掉的数量
- [ ] `tests/unit` 参与 typecheck
- [ ] 附录 C 基线已填写

---

## 6. 阶段 1：目录与仓库整理

### 6.1 目标
目录按领域分组，资源、脚本和设计素材各归其位，开发版笔记库搬出构建目录。除 PR 1.8（开发版默认笔记库路径，只影响开发版）外，**不改任何类型名或逻辑**；发布版二进制在行为上与之前一致。

### 6.2 策略
- SwiftPM 会递归收集 target 目录下的源文件，**target 内部建子目录不需要改 `Package.swift`**；只有测试目录迁移需要加 `path:`。
- 每个 PR 先提交纯 `git mv`，再提交路径引用修复。
- 资源迁移以 bundle 内容不变为验收依据。

### 6.3 执行细节

#### PR 1.1 PlumeKit 按领域分组
```
Sources/PlumeKit/
├── Notes/        NoteFilename  NoteNaming  NoteIndex  NoteOrdering
│                 MarkdownDocument  MarkdownExport  LinkTarget
├── Vault/        VaultIO  VaultLifecycle  VaultSync  VaultWatcher  RecentlyDeleted
├── GitSync/      GitRunner  GitSyncEngine  GitSyncPresentation  GitSyncTypes  GitSyncValidation
├── Persistence/  AppState  Settings  JSONFileStore
├── Panel/        PanelGeometry  SpaceAssignmentPolicy  DockSpaceAssignment
├── Input/        Hotkey  HotkeyPress
└── Support/      Localization  BuildProfile  ReleaseCheck
```
- **必须同步修改**：`Scripts/test-dev-isolation.sh` 第 80 行的 `swiftc Sources/PlumeKit/*.swift …` 用 shell 通配符只匹配根目录，分组之后会漏掉全部源文件，导致编译失败。改为 `swiftc $(find Sources/PlumeKit -name '*.swift') …`。
- 注释里的路径也要同步更新：`Scripts/build-app.sh` 第 128 行、`Editor/build.mjs` 第 25 行，它们引用了 `Sources/PlumeKit/Localization.swift`。
- 验收：`swift build` 通过；`git log --follow Sources/PlumeKit/Notes/NoteFilename.swift` 能看到完整历史。

#### PR 1.2 Plume（App target）按职责分组
```
Sources/Plume/
├── App/          main.swift  AppDelegate  Localization
├── Panel/        PlumeController  PlumePanel  AutoSizeBadge
├── Bridge/       EditorWebView
├── Spaces/       Spaces  SpaceNotice  DockSpaceAssignmentMonitor
├── MenuBar/      MenuBarController
├── Services/     VaultService  StateStore  GitSyncController  UpdateChecker  GlobalHotkey
└── Settings/     （保持不变）
```
`Services/` 是过渡目录：除 `GlobalHotkey` 外，其余文件在阶段 3 会下沉到 PlumeKit，届时这个目录只剩下 AppKit 适配层。

#### PR 1.3 测试迁移到 `Tests/`
- `git mv Sources/PlumeKitTests Tests/PlumeKitTests`，`Package.swift` 改为
  `.executableTarget(name: "PlumeKitTests", dependencies: ["PlumeKit"], path: "Tests/PlumeKitTests")`。
- 测试文件按 PlumeKit 的结构分组：

  | 子目录 | 文件 |
  |---|---|
  | `Notes/` | NoteFilename, NoteNaming, NoteIndex, NoteOrdering, NoteTitleCorpus, MarkdownDocument, MarkdownExport, LinkTarget |
  | `Vault/` | VaultIO, VaultSync, RecentlyDeleted, WelcomeNote |
  | `GitSync/` | GitSync, GitSyncMore（阶段 2 拆分改名） |
  | `Persistence/` | Settings, State |
  | `Panel/` | PanelGeometry, AutoSizing, DockSpaceAssignment |
  | `Input/` | HotkeyPress |
  | `Support/` | Localization, BuildProfile, ReleaseCheck |
  | 根目录 | `main.swift`、`Harness.swift`、`.swiftlint.yml`、`Fixtures/` |

- 需要同步修改：`Package.swift` 的注释、`.swiftlint.yml` 的 `included`、`Scripts/test.sh` 不需要改（它按 product 名构建）。`LocalizationTests` 以 `PLUME_LOCALES` 目录推导仓库根目录，并递归扫描 `Sources/Plume` 和 `Sources/PlumeKit`，**不受影响**。
- 验收：`Scripts/test.sh` 通过，断言数与基线一致。

#### PR 1.4 打包资源归位到 `App/`
- 迁移：
  - `Scripts/Info.plist` → `App/Info.plist`
  - `Scripts/AppIcon.icns`、`Scripts/AppIcon-dev.icns` → `App/AppIcon.icns`、`App/AppIcon-dev.icns`
  - `Resources/MenuBar*.png` → `App/Resources/MenuBar*.png`
- 需要修改的引用（全部已定位）：

  | 文件 | 位置 |
  |---|---|
  | `Scripts/build-app.sh` | 第 112 行（Resources）、第 137 行（Info.plist）、第 166–167 行（icns） |
  | `Scripts/test-dev-isolation.sh` | 第 11 行、第 28–30 行 |
  | `Scripts/make-icons.swift` | 第 12–13 行注释；第 248–249 行的输出目录变量 `scripts`、`resources`；第 295 行和第 322 行的打印 |
  | `Scripts/make-dev-icon.swift` | 第 7–8 行、第 59 行、第 63 行 |

- **bundle 一致性验收**：迁移前后各执行一次（**必须固定构建号**，例如 `PLUME_BUILD=327`；否则 `Info.plist` 里取自提交数的 `CFBundleVersion` 会随提交增加而变化，造成假差异。2026-10-13 实测：固定构建号后清单逐字节一致）
  `PLUME_BUILD=327 Scripts/build-app.sh --release && (cd build/Plume.app && find . -type f -not -path './Contents/_CodeSignature/*' -not -path './Contents/MacOS/*' | sort | xargs shasum) > /tmp/bundle-{before,after}.txt`，
  然后 `diff` 两份结果应为空。

#### PR 1.5 合并 WKWebView 测试脚本，整理 `Scripts/`
- 新增 `Scripts/test-web.sh <suite…> [--skip-editor]`，内置套件表：

  | suite | 测试文件 | 宽度 | 额外行为 |
  |---|---|---|---|
  | commands | `commands.test.js` | 默认 | |
  | markdown | `markdown.test.js` | 默认 | `tee markdown-findings.txt` |
  | switcher | `switcher.test.js` | 默认 | |
  | space-assignment | `space-assignment.test.js` | 默认 | |
  | narrow | `narrow.test.js` | 380 | |
  | tooltip | `tooltip.test.js` | 默认 | |
  | i18n | `i18n.test.js` | 默认 | |

  不带参数时跑全部套件。
- 删除 `test-editor.sh`、`test-markdown.sh`、`test-switcher.sh`、`test-tooltip.sh`、`test-i18n.sh`；更新 `test-all.sh`。
- `Scripts/` 整理为：
  ```
  Scripts/
  ├── build-app.sh  make-dmg.sh  notarize.sh  check-commit-msg.sh     # 构建/发布/CI
  ├── check-doc-refs.sh  doc-refs.baseline                            # 文档引用棘轮（PR 0.6）
  ├── test.sh  test-web.sh  test-keyboard.sh  test-all.sh  test-dev-isolation.sh  # 测试入口
  ├── tools/   dev-app.swift  editor-probe.swift  make-icons.swift  make-dev-icon.swift
  └── smoke/   t1.swift
  ```
  需要同步修改：
  - `Makefile` 第 27 行（`dev` 目标引用 `Scripts/dev-app.swift`）；`test-dev-isolation.sh` 第 7 行。
  - **仓库根目录的推导**：`make-icons.swift` 第 243–245 行和 `make-dev-icon.swift` 第 6 行都用"脚本所在目录的上一级"作为仓库根。搬进 `Scripts/tools/` 后要多向上一级，否则会在 `Scripts/` 下找 `Design/`。`dev-app.swift` 和 `editor-probe.swift` 的路径都从参数传入，不受影响。`smoke/t1.swift` 的目录层级不变。
- 自检：搬完后执行 `swift Scripts/tools/make-dev-icon.swift`，`git status` 应显示 `App/AppIcon-dev.icns` 无变化；如果生成过程不是逐字节确定的，就以输出尺寸和目视检查为准。
- 验收：`make test-all` 的套件数与断言数和基线一致；`ls Scripts/*.sh | wc -l` = 10（v1 写的 8 漏算了 `test-keyboard.sh`，它是 Node 的按键表套件，不属于 WKWebView；也没有算阶段 0 新增的 `check-doc-refs.sh`。实施时已更正，没有为凑数而合并脚本）。

#### PR 1.6 Editor 源码与测试分组
```
Editor/src/
├── main.ts  i18n.ts  index.html  virtual-locales.d.ts
├── bridge/     protocol.ts           ← 从 main.ts 抽出 OutboundMessage、Rect、Window 全局声明（只移动类型）
├── markdown/   blocks  caret  decorate  dialect  live-preview  reveal
│               renumber  list-indent  note-title  word-count
├── keyboard/   （保持不变）
├── ui/         action-panel  find  format-bar  overlay  switcher  tooltip
└── styles/     （保持不变；文件名属于内部实现，不在主题接口内）
Editor/tests/
├── unit/       （保持不变）
├── webview/    commands  markdown  switcher  space-assignment  narrow  tooltip  i18n (.test.js)
└── theme-contract.mjs  theme-api.txt  bridge-names.txt
```
- 需要同步修改：`main.ts` 的 import 路径；`tests/unit/*.test.ts` 中对 `../../src/reveal`、`../../src/blocks`、`../../src/caret`、`../../src/dialect` 的引用；`Scripts/test-web.sh` 中的测试路径。`build.mjs` 的入口 `src/main.ts` 和模板 `src/index.html` 不变。
- 验收：`npm run typecheck` 通过；`dist/index.html` 迁移前后的**功能**一致（全部 webview 套件通过）。esbuild 输出顺序可能变化，所以不要求字节一致。

#### PR 1.7 设计素材归位，删除未用截图
依赖 PR 1.4（图标输出路径）和 PR 1.5（脚本位置），放在它们之后做。

**截图**（已确认删除）：
- `git rm` 以下 5 个文件：`artifacts/plume-actions.png`、`artifacts/plume-dark.png`、`artifacts/plume-settings.png`、`artifacts/plume-switcher.png`、`artifacts/ScreenShot_2026-10-11_025745_836@2x.png`。
- 已核实：`README.md` 和 `README.zh-CN.md` 都只引用 `plume-icon.png` 和 `plume-hero.png`。`artifacts/` 目录名当时不变（2026-10-13 之后为统一首字母大写改名为 `Artifacts/`，见 A.9）。

**设计素材**（全部保留，只重新组织）：
```
Design/
├── README.md                      # 新增：目录说明、定稿与探索稿的对应关系、重新生成图标的命令
├── Icons/
│   ├── AppIcon.png                # 定稿，make-icons 的输入（1024×1024）
│   ├── MenuBarIcon.png            # 定稿，make-icons 的输入（1024×1024，单色）
│   └── Explorations/
│       ├── AppIcon/               # 原 Material/icon_00…icon_05.png（6 张）
│       └── MenuBarIcon/           # 原 Material/menubaricon_00…02、04…07.png（7 张，原本就没有 03）
├── Specs/
│   └── settings-design-spec.md
└── Notes/
    └── dock-space-detection.md
```
- 只用 `git mv`，文件名保持原样，由目录表达分类，这样历史可以追溯。目录内容已经在历史里，移动不会让 `.git` 变大。
- `Design/README.md` 要写清楚：
  - 每个子目录的用途；
  - 定稿来自哪一版：`Icons/AppIcon.png` 与 `Explorations/AppIcon/icon_05.png` 逐字节相同，`Icons/MenuBarIcon.png` 与 `Explorations/MenuBarIcon/menubaricon_07.png` 逐字节相同（2026-10-13 用 shasum 核实）。探索稿保持原样，作为历史记录；
  - 重新生成的命令：`swift Scripts/tools/make-icons.swift` 输出 `App/AppIcon.icns` 和 `App/Resources/MenuBar{,@2x,@3x}.png`，`swift Scripts/tools/make-dev-icon.swift` 输出 `App/AppIcon-dev.icns`；
  - 新增素材的约定：探索稿放在 `Icons/Explorations/<资产名>/`；确定定稿后替换 `Icons/` 下的同名文件，再重新生成；单个文件超过 10 MB 时先评估 Git LFS（目前最大的一张是 3.3 MB）。
- 同步修改：
  - `Scripts/tools/make-icons.swift` 第 247 行的 `design` 目录改为 `Design/Icons`，第 3 行和第 12–13 行的注释同步更新；
  - `Sources/Plume/Settings/SettingsForm.swift` 第 6 行改为引用 `Design/Specs/settings-design-spec.md`；
  - `dock-space-detection.md` 目前没有被任何文件引用。
- 顺手清理工作区里的 `.DS_Store`。`.gitignore` 已经覆盖了它。
- 验收：
  - `git ls-files artifacts` 只剩 `plume-icon.png` 和 `plume-hero.png`，两份 README 的图片都能正常显示；
  - `git ls-files 'Design/*.png' | wc -l` = 15（13 张探索稿 + 2 张定稿，一张不少），`Design/` 根目录下没有图片，`Design/README.md` 已存在；
  - `git log --follow Design/Icons/Explorations/AppIcon/icon_00.png` 能看到历史；
  - `swift Scripts/tools/make-icons.swift` 能找到输入并成功生成，生成后 `git status` 没有变化（如果生成过程不是逐字节确定的，就以尺寸检查为准）。

#### PR 1.8 开发版笔记库迁到 `~/Documents/Plume-dev` 🧪
**现状**：
- `BuildProfile.swift` 第 91–98 行：开发版（`.scratch`）的默认笔记库是 app 同级的 `build/Plume-scratch`；不是以 .app 形式运行时（裸 probe）用 `~/Plume-scratch`。
- `Settings.migrateDevelopmentVault`（`Settings.swift` 第 549 行起）把更早的默认值 `~/Plume-scratch` 迁到 `build/Plume-scratch`。
- 因为笔记放在 `build/` 下，`Makefile` 的 `clean`（第 37 行起）要逐项跳过 `build/Plume-scratch`，`test-dev-isolation.sh` 还专门测试了这个跳过逻辑。

**做法**：
1. `BuildProfile.defaultVaultPath` 的 `.scratch` 分支统一返回 `"~/Documents/Plume-dev"`，与发布版的 `~/Documents/Plume` 对称，不再依赖 bundle 的位置。`defaultVaultPath(bundleURL:)` 的参数可以删掉，同步修改调用方和测试。
2. `iCloudVaultPath` 的 `.scratch` 分支改为 `~/Library/Mobile Documents/com~apple~CloudDocs/Plume-dev`，让命名保持一致。已经选过 iCloud 的开发版设置里存的是明确路径，不受影响。
3. 迁移：`migrateDevelopmentVault` 识别的"旧默认值"扩展为两个，`~/Plume-scratch` 和 `<bundle 所在目录>/Plume-scratch`（也就是 `build/Plume-scratch`）。只有 `vaultPath` 等于其中之一时，才迁到 `~/Documents/Plume-dev`。沿用现有规则：
   - 先复制到 staging 目录，再原子移动（staging 前缀顺手改为 `.Plume-dev-migration-`）；
   - 目标已存在时绝不合并或覆盖；
   - 源目录保留作备份；
   - 失败时保持原配置不变。
4. `Makefile` 的 `clean` 简化为 `rm -rf .build build $(EDITOR_DIR)/dist`，并删掉目标说明里的 "preserving build/Plume-scratch notes"。
5. 同步修改：

   | 文件 | 改动 |
   |---|---|
   | `BuildProfile.swift` 第 25–26 行的文档注释 | "a vault beside the app bundle" 改为新位置 |
   | `Scripts/smoke/t1.swift` 第 46 行 | `defaultVault` 改为 `~/Documents/Plume-dev`（展开 `~`） |
   | `Scripts/test-dev-isolation.sh` 第 51–56 行 | 断言开发版默认值等于 `~/Documents/Plume-dev`，不再断言"在 app 旁边" |
   | `Scripts/test-dev-isolation.sh` 第 94 行起的 Python 段 | 删除"clean 保留 build/Plume-scratch"的测试，改为断言 `make clean` 后 `build/`、`.build/`、`Editor/dist/` 都不存在 |
   | `BuildProfileTests.swift` | 更新开发版默认路径和 iCloud 路径的期望值；新增用例：两种旧默认值各自的迁移、目标已存在时不迁移、自定义路径不迁移 |
   | `StorageSettingsViewController.swift` 第 77 行 | 注释里的 `…/Plume-scratch` 改为 `…/Plume-dev` |
   | `.github/workflows/ci.yml` 第 110 行 | 注释里的 `~/Plume-scratch` 改为 `~/Documents/Plume-dev` |

**本机现状**（2026-10-13 核实）：
- 开发版的 `~/Library/Application Support/Plume (Debug)/settings.json` 里，`vaultPath` 仍是 `…/plume/build/Plume-scratch`，这个目录里只有 1 篇欢迎笔记；
- `~/Documents/Plume-dev` 已经存在，里面有 `.git/` 和 1 篇欢迎笔记；
- 因为目标已存在，按"绝不合并"的规则自动迁移会跳过。**合入后本机需要手工切换一次**：在开发版的设置 › 存储里选择 `~/Documents/Plume-dev`，或者直接编辑 `settings.json` 的 `vaultPath`。`build/Plume-scratch` 里只有欢迎笔记，没有需要带过去的内容。

**风险**：`~/Documents` 受 macOS 隐私保护（TCC）。ad-hoc 签名的开发版每次重建后，系统可能重新弹出访问授权。现在的 `build/Plume-scratch` 本身就在 `~/Documents/Codespace/…` 下，已经是同样的情况，所以不是新增风险。

**验收**：
- 全新的开发环境（把 `Plume (Debug)` 目录挪走后启动开发版）默认使用 `~/Documents/Plume-dev`；
- `vaultPath` 为两种旧默认值之一、且目标不存在时，笔记被完整迁移，源目录保留；目标已存在时不迁移，配置不变；
- `make clean && make dev` 后开发笔记仍在；
- `test-dev-isolation.sh`、`BuildProfileTests` 通过；发布版默认值仍是 `~/Documents/Plume`，Settings 快照测试无需修改即可通过；
- `grep -rn 'Plume-scratch' Sources Tests Scripts Makefile .github` 只剩迁移逻辑里表示旧默认值的常量及其测试。

#### PR 1.9 注释卫生
- `Editor/src/main.ts:1261`：`showBanner` 的 JSDoc 错放在 `showToast` 上方，移回 `showBanner`。
- `Sources/PlumeKit/Settings.swift` 中 `shortcutActions` 上方叠了 3 段不同年代的 `///` 文档注释，合并为一段。
- **先改用户和外部维护者看得到的引用**（方案 B，规则见附录 A.8）：
  - `Themes/Compact.css`、`Themes/Reading.css` 第 8 行的 "(decision 19)"。这两个文件会被复制到用户的主题目录。
  - `packaging/plume.rb` 第 26 行的 "Decision 35"。这个文件会进入 Homebrew tap。
  - 改完后把 `Scripts/doc-refs.baseline` 下调 3。
- 验收：review 通过；`check-doc-refs.sh` 通过，基线已下调。

### 6.4 阶段 1 验收
- [ ] `Sources/PlumeKit` 根目录下没有 `.swift` 文件；`Sources/Plume` 根目录下没有 `.swift` 文件
- [ ] 测试位于 `Tests/PlumeKitTests`，断言数与基线一致
- [ ] `Scripts/` 下没有非脚本文件；WKWebView 测试只有一个入口 `test-web.sh`
- [ ] bundle 资源清单：文件名集合与迁移前完全相同（23 个）；内容差异只允许来自 PR 1.6（`index.html`，压缩后的标识符因模块顺序而重新命名）、PR 1.9（两个主题 CSS 的注释）和下面"实施中发现的问题"第 2 条（`unit/*.test.mjs`）。2026-10-13 实测：固定 `PLUME_BUILD=327`，11 个文件哈希不同，全部落在上述三类里；`index.html` 用"关闭压缩、去掉注释和空行后比较代码行的多重集合"证明代码一致（两边各 28613 行，差集为 0）
- [ ] `artifacts/` 只剩 README 引用的 2 张图；`Design/` 按 Icons / Specs / Notes 组织，15 张图一张不少，并有 README
- [ ] 开发版默认笔记库为 `~/Documents/Plume-dev`；`make clean` 就是一条 `rm -rf`
- [ ] 用户和外部维护者可见的文件（`Themes/`、`packaging/`）里已经没有对未公开文档的引用

---

## 7. 阶段 2：命名统一

### 7.1 目标
领域词汇统一，文件名等于类型名，概念不重叠。命名规范成文（附录 A），之后的新代码照此执行。

### 7.2 策略
- 改名依靠编译器：Swift 和 TS 都是强类型，漏改会编译失败。
- 持久化的名字不动（第 2 节）：Swift 属性改名，但通过 `CodingKeys` 的 raw value 保持 JSON 键不变。
- 先改 Swift、再改 TS、最后拆文件，每步一个 PR。

### 7.3 执行细节

#### PR 2.1 "Panel" 领域改名（Swift）🧪

| 现名 | 新名 | 备注 |
|---|---|---|
| `PlumeState` | `PanelState` | |
| `AppState.plumes` | `AppState.panels` | `CodingKeys`: `case panels = "plumes"`，**JSON 键不变** |
| `plumeID` / `plumeState`（PlumeController 内部） | `panelID` / `panelState` | |
| `PlumePanel` | `PanelWindow` | 是 `NSPanel` 子类，强调"窗口" |
| `PlumeController` | `PanelController` | 阶段 4 会继续瘦身 |
| `PlumeMessage` | `BridgeMessage` | |
| `PanelGeometry.plumeHeight(forOverlay:)`、`plumeWidth` 等 | `panelHeight(forOverlay:)`、`panelWidth` | |
| `switcherPlumeHeight` / `actionsPlumeHeight` | `switcherPanelHeight` / `actionsPanelHeight` | |
| `isPointerOnPlume` / `closePlume` / `showPlume` | `isPointerOnPanel` / `closePanel` / `showPanel` | |
| `runPlumeWidthTests` | `runPanelWidthTests` | |
| `Settings.shortcutActions` 的 group `"plume"` | `"panel"` | 只是 catalog key 后缀，不持久化；i18n key 同步改为 `shortcutGroup.panel` |
| `shortcuts` 字典中的 `"pinPlume"` | **保持不变** | 已持久化到 `settings.json`；Swift 侧可以加注释说明它的含义是"置顶当前笔记" |
| `// MARK: In-plume shortcuts` 等注释 | "In-panel" | 注释里的 "Plume height" 一类说法一并修正 |

- 操作：用 Xcode 或 SourceKit-LSP 的符号重命名，避免文本替换误伤；完成后执行
  `grep -rnE '\b[a-z]+Plume[A-Z]?|\bplume[A-Z]' Sources Tests`，剩余命中逐条确认属于第 2 节的保留项。
- 验收：D1–D5；阶段 0 的 AppState 夹具测试**不需要修改**即可通过（证明 JSON 键没变）。

#### PR 2.2 "Panel" 领域改名（TS）
- 改：`plumeEl` → `panelEl`、`plumeBox` → `panelBox`、`plumeHeight` → `panelHeight`、`plumeShortcuts` → `panelShortcuts`、`plumeTitleEl` → `panelTitleEl`，以及其他局部变量和函数名。
- **不改**：DOM id 和类名（`#plume`、`.plume`、`.plume__*`、`.plume-*`）、`data-plume-*`、`window.plumeHost`、`plumeDialect`（产品命名空间）。
- 验收：`theme-contract.mjs` 和 `bridge-names.txt` 比对不需要修改即可通过；全部 webview 套件通过（它们依赖 DOM 选择器，而选择器没有变）。

#### PR 2.3 文件名与类型对齐（拆文件）

| 现文件 | 拆分为 |
|---|---|
| `Vault/VaultSync.swift` | `ContentHash.swift`、`VaultSync.swift`（2.4 中改名）、`WritePolicy.swift` |
| `GitSync/GitSyncTypes.swift` | `GitSyncSettings.swift`、`GitSyncFailure.swift`、`GitSyncStatus.swift`（含 `GitSyncFailureTracker`）、`ConflictMarkers.swift`、`GitRemoteAddress.swift`；`MenuBarDot` 移到 `GitSync/MenuBarDot.swift`（它是 Git 状态的展示派生） |
| `GitSync/GitSyncPresentation.swift` | `GitSyncWording.swift`、`GitSyncSchedule.swift` |
| `Vault/VaultLifecycle.swift` | `VaultLifecycle.swift`、`WelcomeNote.swift` |
| `Notes/NoteIndex.swift` | `NoteIndex.swift`、`NoteRecord.swift`、`SwitcherRow.swift`、`NoteSearch.swift` |
| `Persistence/AppState.swift` | `AppState.swift`、`NoteState.swift`、`PanelState.swift`（含 `StoredSize`、`StoredFrame`） |
| `App/Localization.swift`（Plume） | `App/Localizer.swift`（与 PlumeKit 的 `Localization.swift`/`L10n` 区分开） |
| `Settings/ShortcutsSettingsViewController.swift` | 抽出 `PlumeShortcutRecorderView` → `Settings/ShortcutRecorderView.swift`（同时去掉 Plume 前缀） |
| `Settings/AppearanceSettingsViewController.swift` | 抽出 `AccentSwatchButton.swift`、`NSColor+Hex.swift` |
| `Settings/SettingsForm.swift` | 抽出 `SettingsCard.swift`、`SettingsRow.swift`；`extension Settings.Appearance` 移到 `Settings.Appearance+Labels.swift` |
| `Bridge/EditorWebView.swift` | `EditorWebView.swift`、`BridgeMessage.swift`（阶段 3 下沉到 PlumeKit） |

- 规则：主类型 > 30 行，或者与文件主题不同领域的类型，必须单独成文件。
- 验收：`grep -nE '^(public |final |private )*(struct|enum|class|protocol|actor) ' -r Sources | awk` 统计"每个文件的顶层类型"，除小型辅助类型外，类型名都与文件名一致（附录 B 给出检查脚本）。

#### PR 2.4 概念改名

| 现名 | 新名 | 理由 |
|---|---|---|
| `VaultSync`（外部变更协调、回声过滤） | `VaultReconciler` | 与 Git/iCloud "同步"区分 |
| `UpdateChecker`（网络获取） | `ReleaseFetcher` | 与 `ReleaseCheck`（纯版本比较）组成一对，同一概念统一用 Release 前缀 |
| `GitSyncMoreTests.swift` / `runGitSyncMoreTests` | 按主题拆，例如 `GitSyncConflictTests`、`GitSyncScheduleTests`、`GitSyncValidationTests` | 文件名 "More" 不表达内容 |
| `VaultSyncTests` | `VaultReconcilerTests` | 跟随上面的改名 |
| `BuildProfile.scratch` | `BuildProfile.dev` | 与 "Plume Dev"、`com.tiylabs.plume.dev`、`~/Documents/Plume-dev` 统一叫法。**只改 Swift 标识符**，Info.plist 键 `PlumeScratchBuild` 和支持目录名 `Plume (Debug)` 属于冻结项，保持不变 |

- 验收：D1–D4；`grep -rn 'VaultSync\b\|UpdateChecker\|\.scratch\b' Sources Tests` 为空（`GitSync*` 不计）。

#### PR 2.5（可选）i18n key 规范化

> **未实施。** 本轮目标只覆盖 PR 2.1–2.4；可选项没有做。已做的 i18n 改动只有两个与"面板"改名直接相关的 key：`menu.closePlume` → `menu.closePanel`、`shortcutGroup.plume` → `shortcutGroup.panel`（两个语言文件同步，`LocalizationTests` 的 key 扫描通过）。`shortcut.*` / `shortcuts.*` / `shortcutGroup.*` 的合并仍待决定。
- 只处理明显的重复和歧义，不做大搬家：
  - `shortcut.*`（行标签）、`shortcuts.*`（录制器状态）、`shortcutGroup.*` → 统一为 `shortcuts.action.*`、`shortcuts.recorder.*`、`shortcuts.group.*`
  - 确认 `sync.*` 与 `storage.git.*` 的分工（失败原因 vs 设置页文案），在 `Locales/README.md` 中写明。
- 两个语言文件同步修改；`LocalizationTests` 的"代码引用的 key 都已定义"检查会兜底。
- 验收：`Scripts/test.sh` 通过；`Locales/README.md` 新增 "Key 命名" 一节（内容见附录 A.5）。

### 7.4 阶段 2 验收
- [x] 附录 A 命名规范合入：仓库内可见的版本是 `Design/Notes/naming-conventions.md`（`docs/` 不公开，`CONTRIBUTING.md` 此前被有意删除，所以放在 `Design/Notes/`，并从 `Design/README.md` 链接）。它描述的是代码现状，并包含"不能改的名字"一节；`docs/` 里的附录 A 保留为带讨论背景的完整版
- [x] 领域代码中不再有 "plume 表示面板" 的标识符：Swift 侧 B3 为 0；TS 侧只剩 `dataset.plumeTask`、`dataset.plumeDescribed`，它们对应 DOM 属性 `data-plume-*`，属于第 2 节冻结项
- [x] 文件名与主类型名一致性检查通过：B1 从 40 条降到 14 条，剩下的都是依附主类型的小型辅助类型（私有视图、基类、`StoredSize`/`StoredFrame`、`KeyCode`、`VaultError` 等）；`main.swift` 按角色命名。方案表里没有列、但同样违反规则的 `SettingsStore`（`StateStore.swift` 内）和 `L10n`（`Localization.swift`，已改名为 `L10n.swift`）一并处理了
- [~] 兼容性快照测试**没有任何修改**：**字面上没有做到，实质上做到了**。`CompatibilityTests.swift` 有且只有 4 行不同（第 79–82 行 `state.plumes` → `state.panels`），因为测试要读的 Swift 属性按 PR 2.1 改名了，这 4 行不改就无法编译。3 个 JSON 夹具、全部 JSON 键断言（`out["plumes"]`、`out["panels"] == nil` 等）、`theme-contract.mjs`、`theme-api.txt`、`bridge-names.mjs`、`bridge-names.txt` 与阶段 0 提交逐字节相同（2026-10-13 用 `cmp` 核实）。把 `CodingKeys` 的映射去掉后 6 条断言变红，证明 JSON 键确实被钉住。本条要证明的是"JSON 键没变"，这一点成立

---

## 8. 阶段 3：模块边界纠正 + 桥接契约

### 8.1 目标
- 所有不依赖 AppKit 的逻辑进入 PlumeKit，并补上单测；
- App target 只剩 AppKit/WebKit/Carbon 适配层和 UI；
- 桥接协议两端由测试强制保持一致。

### 8.2 策略
- **依赖倒置**：PlumeKit 定义协议（`Scheduling`、`VaultServicing`、`HTTPFetching`），App target 提供基于系统 API 的实现，测试提供 fake 实现。
- **时间可控**：所有防抖、合并、定时逻辑通过 `Scheduling` 注入，测试中用 `ManualScheduler` 手动推进时间。
- 每次下沉一个服务，一个服务一个 PR，并且同一个 PR 内补上该服务的测试。

### 8.3 执行细节

#### PR 3.1 引入 `Scheduling`，下沉 Persistence 🧪
- 新增 `PlumeKit/Support/Scheduler.swift`：
  ```swift
  public protocol Cancellable { func cancel() }

  @MainActor
  public protocol Scheduling {
      @discardableResult
      func schedule(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) -> any Cancellable
  }

  public struct MainQueueScheduler: Scheduling { … }     // DispatchQueue.main.asyncAfter
  public final class ManualScheduler: Scheduling {        // 仅测试使用
      public func advance(by seconds: TimeInterval)
  }
  ```
  `ManualScheduler` 放在测试 target 中，或者用 `#if DEBUG` 包起来，不进入发布二进制。
- `StateStore`、`SettingsStore` 迁移到 `PlumeKit/Persistence/`：去掉 `import AppKit`（实际只用到 `NSLog`，Foundation 里就有）；`StateStore` 的 2 秒合并改用注入的 `Scheduling`；构造函数支持注入 `JSONFileStore`（测试使用临时目录）。
- 补充测试：合并写入（2 秒内多次 `update` 只写一次）、`save()` 立即落盘、`SettingsStore.update` 值不变时不写盘也不回调、`reloadFromDisk` 能区分自己的写入和外部编辑、dev 隔离（`isolateDevelopmentSettings`）。
- 验收：D1–D5；`Sources/Plume` 中不再有 `StateStore.swift`。

#### PR 3.2 下沉 `VaultService`，抽出 `VaultServicing` 🧪
- `VaultService.swift`（561 行，只依赖 Foundation）迁移到 `PlumeKit/Vault/`。
- 抽出 `public protocol VaultServicing: AnyObject, Sendable`，包含 `PanelController` 实际用到的方法（`rows`、`present`、`load`、`download`、`diskState`、`write`、`create`、`delete`、`rename`、`renameFollowingTitle`、`harvestConflicts`、`findRenamed`、`keepDeleted`、`forgetIndexed`、`noteBufferChanged`、`deletedRows`、`restoreDeleted`、`forgetDeleted`、`setVault`），`PanelController` 改为依赖协议。
- 补充测试（使用临时目录下的真实 vault）：串行顺序（先 write 后 delete，Recently Deleted 中是最新内容）、`expectedHash` 不匹配时生成冲突副本、`present` 能反映外部新增的文件。
- 验收：D1–D5。

#### PR 3.3 下沉 `ReleaseFetcher`
- `UpdateChecker`（阶段 2 中已改名为 `ReleaseFetcher`）迁移到 `PlumeKit/Support/`，网络调用经由注入的 `HTTPFetching`（默认实现包装 `URLSession`）。
- 测试：用 stub 返回 GitHub API 的 JSON，覆盖有新版本、已是最新、解析失败、网络失败四种情况。
- 验收：D1–D4；网络失败不抛到 UI（与现状一致）。

#### PR 3.4 拆分 `GitSyncController` 🧪
- 拆为两部分：
  - `PlumeKit/GitSync/GitSyncScheduler.swift`（纯逻辑，`@MainActor`）：5 分钟周期、启动后延迟、唤醒后延迟、手动 Sync Now、运行期间的请求合并、写入活跃时推迟（`postponements`）、退出时只提交不推送、失败计数。依赖 `Scheduling` 和一个 `GitSyncCycleRunning` 协议（包装 `GitSyncEngine`）。
  - `Sources/Plume/Services/GitSyncController.swift`（薄壳）：只负责订阅 `NSWorkspace.didWakeNotification`，把事件转给 scheduler。
- 测试：周期触发；运行中再次请求，结束后只补跑一次；有写入活动时定时周期被推迟，Sync Now 不被推迟；退出路径只调用 commit；连续失败时状态从 syncing 变为 failed 的阈值。
- 验收：D1–D5；`GitSyncController.swift` ≤ 80 行。

#### PR 3.5 桥接契约 🧪
目标：两端任何一侧新增、删除或改名消息时，**测试会失败**。

1. **TS 侧单一事实源**（`Editor/src/bridge/protocol.ts`）：
   ```ts
   export type OutboundMessage = | { type: "ready" } | …;          // 已在 1.6 抽出
   export interface HostAPI {                                       // 新增：入站方法表
     loadNote(filename: string, text: string, caret: number, pinned: boolean): void;
     showToast(text: string, dwell?: number): void;
     // …其余 21 个
   }
   ```
   `main.ts` 中改为 `const host: HostAPI = { … }`，由 TS 编译器保证 `host` 实现了这个接口。
2. **Swift 侧强类型**：
   - `BridgeMessage` 迁移到 `PlumeKit/Bridge/`，解码由手写字典改为 `Decodable`（`type` 作为判别字段）；`static let knownTypes: Set<String>` 由 `CaseIterable` 风格的辅助枚举生成。
   - 新增 `EditorCommand` 枚举，替代 `editor.call("…", [...])` 和 `callJSON`：
     ```swift
     public enum EditorCommand {
         case loadNote(filename: String, text: String, caret: Int, pinned: Bool)
         case showToast(String, dwell: Int? = nil)
         case setNoteFilename(String)
         case showDeleted([SwitcherRow])
         // …
         public var method: String { … }
         public func encodedArguments() throws -> String { … }   // JSON 编码统一在这里处理
     }
     ```
     `EditorWebView` 只暴露 `send(_ command: EditorCommand)`。
3. **契约测试**（`Tests/PlumeKitTests/Bridge/BridgeContractTests.swift`，与 `LocalizationTests` 扫描源码的做法相同）：
   - 用正则从 `protocol.ts` 提取 `OutboundMessage` 中全部 `type: "(\w+)"`，与 `BridgeMessage.knownTypes` 比较，要求集合相等；
   - 提取 `HostAPI` 的方法名和参数个数，与 `EditorCommand` 的 `method` 和参数个数比较，要求相等；
   - 对每种入站消息，用一份 JSON 夹具解码，断言能得到对应的 case（字段名拼错时会失败）。
4. 删除阶段 0 的 `bridge-names.txt` 过渡检查。

- 验收：手工删掉 TS 侧任意一个消息类型，或者把 Swift 侧某个字段名改错，`Scripts/test.sh` 都会变红；`grep -rn 'call("' Sources/Plume` 为空。

### 8.4 阶段 3 验收
- [x] `Sources/Plume` 中没有只 import Foundation 的文件（2026-10-13 实测为 0；`Services/` 里只剩 `GlobalHotkey` 和 80 行以内的 `GitSyncController` 外壳）
- [x] PlumeKit 新增测试覆盖 Persistence（`StoreTests`）、VaultService（`VaultServiceTests`）、ReleaseFetcher（`ReleaseFetcherTests`）、GitSyncScheduler（`GitSyncSchedulerTests`）、Bridge（`BridgeContractTests`）
- [x] 桥接契约测试生效：两种手工破坏方式都会被发现（见下面"实施记录"的变异清单）
- [x] 断言总数比基线有明显增加：PlumeKit 从 2987 增至 3301（+314），测试从 456 增至 528（+72）；WKWebView 套件 1419 不变

#### 实施记录（与方案的差异）

- **PR 3.1**：`Scheduling` 协议多了一个 `repeating(every:tolerance:)`，因为 Git 同步的 5 分钟周期原来是 `Timer`，不能用链式 `asyncAfter` 代替（`Timer` 按墙钟走，睡眠期间到期的会在唤醒时触发；dispatch 时钟睡眠时停表）。`ManualScheduler` 放在测试 target（`Tests/PlumeKitTests/Support/`），没有进入发布二进制。`SettingsStore` 额外接受 `profile`、`bundleURL`、`homeDirectory`，开发版隔离和旧库迁移因此可测。测试 harness 增加了 `Check.mainSuite` / `Check.mainTest`，只给被测对象是 `@MainActor` 的测试用，普通测试的闭包不变。
- **PR 3.2**：`VaultService` 的 5 个内嵌结果类型提到了顶层并加 `Vault` 前缀（`VaultSnapshot`、`VaultLoadResult`、`VaultDiskState`、`VaultWriteResult`、`VaultRenameResult`），放在 `VaultResults.swift`。协议按计划列出的方法清单实现（含 `setVault`、`present`），不含 `drain`、`purgeDeleted`、`titles`：这三个只有 `AppDelegate` 调用，它直接依赖具体类型。`setVault` 和 `present` 在协议里但 `PanelController` 并不调用，只有 `AppDelegate` 用；要不要从协议里去掉，留到阶段 4 拆 `AppCoordinator` 时再看。`init` 增加了 `deletedStore:` 参数，让测试不碰真实的 Application Support。`writeDelayForTesting` 是一个测试钩子，默认 0；没有它，"delete 逃出串行队列"的变异测不出来。
- **PR 3.3**：`HTTPFetching` 只返回 `(Data?, Error?)`，没有响应对象，因为 Plume 唯一的请求把所有失败当成同一种（`.unknown`）。
- **PR 3.4**：`GitSyncScheduler` 的 `init` 不给默认参数（默认参数在 actor 外求值，而 `MainQueueScheduler` 等是 `@MainActor`）。`swift build` 不报这个错，`Scripts/test-dev-isolation.sh` 里用 bare `swiftc` 编译 PlumeKit 才报，已修。`GitSyncEngineRunner` 的串行队列是静态的，旧目标和新目标不会同时对同一个目录跑 Git。`GitSyncController` 由 255 行降到 42 行。
- **PR 3.5**：计划里的"`BridgeMessage` 改为 `Decodable`"已做；解码保持原来的宽松语义（缺字段读作零值，`navigate.back` 缺省为 `true`，未知 `type` 丢弃）。`EditorCommand.encodedArguments()` 返回逐个 JSON 字符串；JSON 编码与旧的 `JSONSerialization` 路径逐字一致（包括把 `/` 转义为 `\/`、U+2028、`</script>`），这一点是单独比对过的，因为计划原则 1 要求行为不变。`HostAPI` 里的类型（`NoteSummary`、`SpaceAssignmentState`、`DockSpaceAssignmentState`、`PanelSettings`）从 `switcher.ts`、`action-panel.ts`、`main.ts` 移到了 `bridge/protocol.ts`。`Editor/tests/bridge-names.{mjs,txt}` 已删除，契约测试取代了它。

##### 契约测试的变异验证（2026-10-13）

| 破坏方式 | 被谁发现 |
|---|---|
| TS 侧删掉 `toggleFooterCount` 消息 | `BridgeContractTests`：Swift 解码的类型集合与页面不一致 |
| TS 侧删掉 `hideBanner` 方法 | 同上：`EditorCommand` 与 `HostAPI` 的方法集合不一致，且 `main.ts` 的 `tsc` 也会失败 |
| TS 侧给 `setPointer` 多加一个参数 | 参数个数检查 |
| Swift 侧 `setPointer` 少传一个参数 | 参数个数检查 |
| Swift 侧把方法名拼错 | 方法集合检查 + 参数个数检查 |
| Swift 侧把 `scrollLine` 读成别的键名 | "页面发送的每个字段都被读取" |
| Swift 侧忽略 `navigate.back` | 同上 |
| Swift 侧改了 `applySettings` 的某个键名 | `applySettings` 键集合与 `PanelSettings` 不一致 |

另有 StateStore（去掉合并窗口的重置）、VaultService（delete 逃出串行队列、冲突检测关掉）、GitSyncScheduler（5 种）的变异检查，都被对应测试发现。

##### 运行时验证

用真实打包的 `Editor/dist/index.html` 在真实 WKWebView 里，把 23 个 `EditorCommand` 的 `script` 逐个执行，包含含反引号、`</script>`、U+2028、emoji、`${x}` 的文本：无 JS 异常，文档内容、标题、置顶、保持置顶、外观、字号、强调色、悬停状态都按预期落在 DOM 上。**这不能替代附录 D 的手工清单和 smoke t1**，那两项依赖运行中的开发版，仍需要你执行。

---

---

## 9. 阶段 4：拆分上帝对象

### 9.1 目标
- `PanelController`（原 `PlumeController`）≤ 600 行，只管窗口；
- 笔记会话状态机进入 PlumeKit 的 `NoteSession`，并有场景测试覆盖；
- `AppDelegate` ≤ 250 行；`main.ts` ≤ 300 行；`format-bar.ts` 拆为 UI 和命令两部分。

### 9.2 策略：先接缝，再搬迁，后补测试

```
4.1 原地引入接缝 ──▶ 4.2 原样搬迁到 NoteSession ──▶ 4.3 场景测试 ──▶ 4.4 Router ──▶ 4.5 收尾
   （行为不变，diff 小）    （代码基本照搬）            （锁住行为）
```

`PlumeController` 依赖 AppKit，不能先写测试，所以 4.1 和 4.2 依靠 smoke t1 和手工清单兜底。4.3 完成后，会话逻辑就有了单测保护，之后的改动可以更放心。

### 9.3 执行细节

#### PR 4.1 原地引入接缝 🧪
在 `PanelController` 内部完成以下改动，不移动文件：
1. 把笔记会话对 UI 的全部副作用收拢到一个协议 `NoteSessionOutput` 后面，由 `PanelController` 自己实现。涉及的现有调用：`editor.call("loadNote" | "setNoteFilename" | "setPinned" | "showToast")`、`showBanner`/`hideBanner`、`editor.focusEditor()`、`onPinsChanged`、`refreshSwitcherIfOpen()`、`checkVaultStillThere()`/`onVaultMissing`。
2. `scheduleWrite` 的 500 ms 防抖改用注入的 `Scheduling`。
3. `Banner` 枚举迁移到 PlumeKit（文案改用 `L10n.t`）。
4. 会话代码引用的状态（`currentFilename`、`bufferText`、`baselineHash`、`isDraft`、`isMaterialising`、`isWriting`、`writeRequestedWhileWriting`、`isDownloadingCurrent`、`unsettledName`、`pendingCreatedName`、`lastReportedCaret`、`writeTimer`）集中到一个 `// MARK: - Session` 区块。

- 验收：D1–D5；diff 中没有逻辑变化（reviewer 逐行确认只是替换了调用方式）。

#### PR 4.2 搬迁到 `PlumeKit/Session/NoteSession.swift` 🧪
接口草案：
```swift
@MainActor
public protocol NoteSessionOutput: AnyObject {
    func load(_ note: LoadedNote)                 // filename, text, caret, pinned
    func currentNoteRenamed(to filename: String)  // 冲突副本、标题跟随、手工改名
    func pinnedChanged(_ pinned: Bool)
    func show(_ banner: Banner?)                  // nil = 隐藏
    func toast(_ text: String)
    func focusEditor()
    func pinsChanged()
    func switcherNeedsRefresh()
    func vaultMayBeMissing()
}

@MainActor
public final class NoteSession {
    public init(panelID: UUID,
                vault: any VaultServicing,
                state: StateStore,
                settings: SettingsStore,
                scheduler: any Scheduling,
                output: any NoteSessionOutput)

    public private(set) var currentFilename: String?
    public var isDraft: Bool { get }
    public var isPinned: Bool { get }

    // 生命周期与导航
    public func openLastUsed()
    public func open(_ filename: String, recordingHistory: Bool = true)
    public func create(title: String)
    public func duplicate(text: String)
    public func delete(_ filename: String)
    public func togglePin(_ filename: String?)
    public func rename(to newName: String)        // NSAlert 输入框仍由 PanelController 负责
    public func left()                            // dismiss / 切走 / 退出：标题定稿

    // 编辑器事件
    public func edited(text: String, caret: Int)
    public func caretMoved(_ caret: Int, scrollLine: Int)
    public func flush(trigger: WritePolicy.Trigger)

    // 外部事件
    public func vaultChanged(filenames: [String])
}
```
- 迁移范围（按现有 MARK 分区）：`// MARK: - Notes`（约第 586–900 行）、`// MARK: - Writing`、`// MARK: - The filename follows the title`、`// MARK: - External changes`（约第 1148–1390 行）。
- `renameFileByHand` 拆开：`NSAlert` 输入部分留在 `PanelController`，调用 `session.rename(to:)`。
- 历史记录（`recordVisit`/`goBack`/`goForward`）抽成 `PlumeKit/Session/NavigationHistory.swift`（纯值类型），由 `NoteSession` 持有。
- 搬迁提交之后，在同一个 PR 里追加一个只改注释的提交，把 `NoteSession.swift` 中的文档引用改写掉（规则见附录 A.8）。`PlumeController.swift` 有 94 处引用，是全仓库最密的文件，其中大部分会随会话代码搬过来。改完后下调基线。
- 验收：D1–D5、D8；`PanelController` 中不再出现 `bufferText`、`baselineHash`、`isDraft` 等字段；`NoteSession.swift` 里没有对未公开文档的引用。

#### PR 4.3 NoteSession 场景测试
测试工具（放在 `Tests/PlumeKitTests/Session/Support/`）：
- `FakeVault: VaultServicing`：内存文件表；每个异步操作的完成回调**排队，由测试手动释放**，用来模拟"操作在途"；
- `ManualScheduler`；
- `RecordingOutput: NoteSessionOutput`：按顺序记录全部副作用。

场景清单（每一条都对应代码注释中记录过的真实 bug）：

| # | 场景 | 断言 |
|---|---|---|
| S1 | 空草稿、纯空白草稿后切走 | 不创建任何文件 |
| S2 | 草稿首次 flush | 创建文件；创建在途期间继续输入的内容在创建完成后补写 |
| S3 | 写入在途时再次 flush | 只追加一次后续写入，不会产生冲突副本 |
| S4 | `expectedHash` 不匹配 | 切换到冲突副本；baseline 更新；输出 `currentNoteRenamed` 和 conflict banner |
| S5 | 防抖窗口内删除 | 先写最新内容再删除；retry 标志被清除，文件不会被重新创建 |
| S6 | 下载在途时继续输入，然后下载完成 | 在途期间的输入写入旧笔记，不丢失 |
| S7 | 标题跟随改名 | 只在写入完成且没有挂起写入时改名；外部写入或 `left()` 之后定稿 |
| S8 | 打开不存在的笔记 | 移除该笔记的状态并回退到最近的笔记；空 vault 最终进入草稿，并且流程终止 |
| S9 | 草稿落盘 | 新条目的 caret 使用最近一次上报的值 |
| S10 | 尾换行差异 | buffer 只差一个尾换行时不会触发写入（不会每 500 ms 重写一次） |
| S11 | 外部修改 | 自己写入的回声不触发重载；外部内容变化时重载并保留 caret；文件被驱逐时显示 downloading banner |
| S12 | 外部重命名 | 跟随到新文件名，并更新 `PanelState.noteFilename` |
| S13 | 置顶切换 | 输出 `pinnedChanged`、`pinsChanged`、`switcherNeedsRefresh` |
| S14 | 前进/后退 | 由导航触发的打开不写入历史；已删除的笔记不出现在历史中 |

- 验收：14 个场景全部通过；新增断言数记入附录 C。

#### PR 4.4 `EditorBridgeRouter`
- `PanelController.editor(_:didReceive:)` 中约 200 行的 `switch`（`PlumeController.swift:1661` 起）迁移到 `Sources/Plume/Bridge/EditorBridgeRouter.swift`，按目标分发：
  - 会话类（`edited`、`caret`、`openNote`、`createNote`、`togglePin`、`deleteNote`、`duplicateNote`、`renameFile`、`navigate`）→ `NoteSession`
  - 窗口类（`contentHeight`、`switcherOpen`、`actionsOpen`、`dragRegions`、`toggleAutoSizing`、`toggleKeepOnTop`、`toggleHideFromCapture`、`setSpaceAssignment`、`headingMenu`、`close`）→ `PanelController`
  - 设置类（`textSize`、`toggleFooterCount`）→ `SettingsStore`
  - Vault 类（`requestNotes`、`requestDeleted`、`restoreDeleted`、`forgetDeleted`）→ `VaultServicing`
  - 系统类（`openLink`、`revealInFinder`、`copyAsMarkdown`、`exportNote`、`openSettings`）→ 一个小的 `SystemActions`
- 保留现有的 "先读出 `settings.value` 再在 `update` 闭包外使用" 的写法（`toggleFooterCount` 注释里记录过的崩溃）。
- 验收：D1–D5；router 中每个 case ≤ 10 行。

#### PR 4.5 `PanelController` 收尾
- 剩余职责：窗口创建与 park、召唤/隐藏、Space 策略、几何与自动尺寸、hover/指针跟踪、防截屏、主题 CSS 加载、导出面板。
- 如果仍然超过 600 行，按 MARK 拆分为 `PanelController+Spaces.swift`、`PanelController+Hover.swift`、`PanelController+Geometry.swift`（同类型的 extension 文件）。
- 验收：`PanelController.swift` ≤ 600 行；lint 的 `type_body_length` 阈值可以收紧到 700。

#### PR 4.6 `AppDelegate` 瘦身 🧪
| 新类型 | 来源（AppDelegate 中的 MARK） |
|---|---|
| `AppCoordinator` | 组装：创建 stores、services、`PanelController`、菜单栏，并接好各个回调；`applicationDidFinishLaunching` 的主体 |
| `VaultCoordinator` | `// MARK: - Vault`：`prepareVault`、`handleVaultMissing`、`presentVaultChooser`、`startWatching`、`pruneStateForMissingNotes` |
| `UpdateCoordinator` | `// MARK: - Updates`：`checkForUpdateIfDue`、`recordUpdateStatus`、`announceUpdate` |
| `MainMenuBuilder` | `// MARK: - Main menu`：`installMainMenu`、`applyMenuShortcuts` |
| `AppDelegate` | 只保留 `NSApplicationDelegate` 回调，转发给 `AppCoordinator` |

- 验收：`AppDelegate.swift` ≤ 250 行；冷启动、退出时 flush、语言切换（关闭并重建设置窗口）都正常。

#### PR 4.7 Editor：拆分 `main.ts`
```
src/main.ts               启动：创建 view、挂载 UI、注册 host、发送 ready（≤ 300 行）
src/editor/setup.ts       EditorView 扩展装配、compartments、快捷键表 plumeShortcuts→panelShortcuts
src/editor/chrome.ts      标题、字数、toast、banner、拖拽区域上报、高度上报
src/bridge/host.ts        const host: HostAPI = {…}（原 main.ts 第 1046–1293 行）
src/bridge/send.ts        send()
```
- 注意模块之间的初始化顺序：`host.ts` 依赖 `view`，用工厂函数 `createHost(deps)` 注入，避免模块顶层产生副作用。
- 验收：全部 webview 套件通过；`main.ts` ≤ 300 行。

#### PR 4.8 Editor：拆分 `format-bar.ts`
```
src/format/inline.ts      activeMarks、enclosingPair、unwrap、toggleWrap、pendingWrap 等（原第 298–760 行）
src/format/block.ts       openList、applyBlockMarker、applyOrderedList/Bullet/Task/Quote/CodeBlock、setHeading（原第 764–1250 行）
src/format/keys.ts        MARKDOWN_FORMAT_KEYS
src/ui/format-bar.ts      BUTTONS、icon、mountFormatBar（≤ 450 行）
```
- 新增 `tests/unit/format-inline.test.ts`、`format-block.test.ts`，沿用现有"表驱动、`|` 表示光标"的风格；先把 `commands.test.js` 中 "11 个命令 × 5 种选区" 的核心用例迁移成表格用例，WKWebView 套件继续负责渲染层面的验证。
- 验收：`format-bar.ts` ≤ 450 行；新增单测用例 ≥ 55 条（11 × 5）。

### 9.4 阶段 4 验收
- [x] 不存在 `PlumeController`；`PanelController` ≤ 600 行（493）；任何 Swift 文件 ≤ 800 行（最大 `NoteSession.swift` 702）
- [x] `NoteSession` 的场景测试全部通过：方案列的 14 个场景都有，另有 26 个相邻场景，共 40 个（`NoteSessionTests`，577 个测试里的一部分）
- [x] `AppDelegate` ≤ 250 行（28）；`main.ts` ≤ 300 行（260）；`format-bar.ts` ≤ 450 行（353）
- [x] SwiftLint 收紧到阶段 4 的阈值后仍为绿：file 800 / type body 450 / function body 100（比方案写的 1000 / 700 / 150 更严，因为代码实测远低于它）
- [ ] 使用 dev 构建作为日常主力 ≥ 3 天，期间没有回归，然后再合入 master 发布 —— **未做，也不是能在实施中完成的事**

#### 实施记录（与方案的差异）

- **顺序**：方案是 4.1 接缝 → 4.2 搬迁 → 4.3 测试。实际是把 4.1 和 4.2 合成一步（先抽出 `NoteSessionOutput`，再把代码搬过去，没有先在原文件里做一轮接缝），然后补 4.3。原因：4.1 要在 AppKit 类里原地替换调用，而搬迁本身就是做这个替换，分两步只会让同一批行改两遍。代价是 4.2 没有测试兜底，靠的是下面三条。
- **4.2 的兜底**：（1）搬迁前后的代码行做了多重集合对比，除预期的机械替换（`editor.send` → `output.*`、`DispatchWorkItem` → `Scheduling`、`tr` → `L10n.t`、`private` 放宽）外无差异；（2）smoke t1 在**改动前**的 `2a1c8ff` 上和改动后各跑一遍，62 项逐条一致（见下）；（3）对 `NoteSession` 做 8 种变异验证。
- **`NoteSession` 的接口**：与草案基本一致，差别是 `rename(toTyped:)` 取代了 `rename(to:)`（slug 和唯一化在会话里做，对话框留在面板），多了 `openLastUsedIfNothingOpen()`、`buffer`，`NoteSessionOutput` 多了 `news(_:)` 和 `isPanelVisible`（"在隐藏的面板里加载笔记不抢键盘"这条规则要读它），`vaultMayBeMissing` 改名 `vaultIsGone`（会话自己判断文件夹是否还在，输出只负责提问）。`NoteSession+External.swift` 是从主文件拆出的同类型 extension，因为主文件 946 行超过了 800。
- **`PanelController` 的拆分**：493 行的主文件 + 6 个同类型 extension 文件（Spaces、Geometry、Capture、Messages、Window、SessionOutput）。拆分是纯移动加把 `private` 放宽为 internal；移动前后的非注释代码行多重集合完全一致，只多 3 对 `extension {}`。
- **`EditorBridgeRouter`**：31 个 case 一个不少，每个 case 一行；各自的函数体是从旧 `switch` 里原样挪到 `PanelController+Messages.swift`。
- **`AppDelegate` 的拆分**：`AppCoordinator`（384 行，持有全部进程级对象）、`VaultCoordinator`、`UpdateCoordinator`、`MainMenuBuilder`；`AppDelegate` 只剩三个系统回调。每个新类型只拿它用到的依赖（`UpdateCoordinator` 不认识设置窗口，`MainMenuBuilder` 只收 4 个闭包）。启动顺序逐行对照过。`AppCoordinator` 仍有 384 行，因为 `settingsChanged` 和 `openSettingsWindow`（合起来约 100 行）还在里面，它们是"应用把各部分接起来"的核心，没有再拆。
- **`main.ts`**：拆成 `editor/{dom,state,ctx,chrome,chrome-tips,setup,overlays,input-rules,select-block,shortcuts}.ts` 和 `bridge/{host,send}.ts`。**与方案不同**：方案说用 `createHost(deps)` 解决顺序问题；实际 `host` 用了，但其余部分（`actions`、`switcher`、`view`、两个底栏）互相引用，所以另加了一个 `ctx` 对象：`main.ts` 启动时把造好的部件放进去，各处理函数在**调用时**才读它。可变状态原来是模块级 `let`，import 进来的绑定不能赋值，所以放进 `state` 对象。验证方式：未压缩 bundle 的代码行多重集合在归一化 esbuild 的重命名后差集为 0。
- **`format-bar.ts`**：拆成 `format/{inline,block,keys}.ts` 和 UI（353 行）。UI 文件保留了 `MARKDOWN_FORMAT_KEYS`、`setHeading`、`pendingPair`、`pendingWrapExtension` 的 re-export，其余 6 个文件的 import 路径没改。验证方式同上，未压缩 bundle 的差集为 0。
- **新增的格式测试**：方案要求 ≥ 55 条，实际 `format-commands.test.ts` 是 105 条（11 命令 × 5 选区 × 两次按键，与 `commands.test.js` 同一份夹具和期望值）+ `format-rules.test.ts` 的 37 条边界用例，键盘表从 187 增到 328。用的是 `StubView`（只有 `state`、`dispatch`、`focus`）跑真实的解析器。变异验证抓到一个漏洞：最初没有任何用例钉住"列表命令作用在另一种列表上是换标记"，补了 9 条之后才被抓到。
- **没有做到的**：`NoteSession` 的变异验证中，"重命名可以在写入进行中开始"这一条（`considerRename` 里的 `!isWriting`）**没有被抓到**，我判断它在当前结构下不可观察：`considerRename` 只从写入完成的回调里被调用，那时 `isWriting` 已经是 false。守卫是冗余的，所以留着，没有为它造测试。

##### 运行时验证（2026-10-13）

- **`Scripts/test-all.sh` 全绿**：PlumeKit 577 个测试 / 3475 断言，键盘表 328 个用例，WKWebView 1419 条断言不变。
- **smoke t1**：62 项里 58 项通过，**4 项失败，在 `2a1c8ff`（重构前）上同样 4 项失败，逐条一致**：`elsewhere` 的两个 toast 断言（脚本写死英文，本机界面是中文）和 `hotkey` 的两个"另一个 app 拿走焦点后面板保持显示"（环境相关）。`AppDelegate` 拆分之后又跑了一遍（62 项，同样的 4 个失败），并且确认了冷启动、手改 `settings.json` 的语言和字号热更新、输入后立即退出时草稿能落盘（笔记文件在，内容完整）。
- **最后一轮（`main.ts` 和 `format-bar.ts` 拆分之后）没能跑 smoke**：本机屏幕在这个时间点被锁定（`CGSSessionScreenIsLocked = Yes`），合成按键进不了面板，连 `2a1c8ff` 的构建也一样呼不出来，所以这不是回归，但也**意味着最后这两步 Editor 拆分没有在真实应用里跑过**。它们的验证来自：1419 条真实 WKWebView 断言、328 条键盘表用例、23 个 `EditorCommand` 的 bridge probe（对真实 bundle，无 JS 异常，DOM 结果与拆分前一致）、未压缩 bundle 代码行差集为 0。**请在屏幕解锁后重跑 `swift Scripts/smoke/t1.swift`**。

---

## 10. 阶段 5：长期项（按需）

| 项 | 内容 | 前置条件 | 验收 |
|---|---|---|---|
| L1 swift-testing 评估与迁移 | `Package.swift:24` 和 `Harness.swift:5` 的前提是"CLT 不带 swift-testing"。但本机 CLT 27 的 `/Library/Developer/CommandLineTools/Library/Developer/Frameworks/` 下已经有 `Testing.framework`，CI 的 `macos-latest` 也装有 Xcode。**先做 spike**：在只装 CLT 的环境（`xcode-select -s /Library/Developer/CommandLineTools`）里，用一个 `.testTarget` 跑通 `swift test`。可行的话，逐套件把 `Check.*` 迁移到 `#expect`，删掉 `main.swift` 里的 24 个手动注册（漏注册等于静默跳过），分片改用 `swift test --parallel` | 阶段 1 完成 | 只装 CLT 时 `swift test` 通过；断言数不少于迁移前 |
| L2 文档引用存量清零 | 已确定采用方案 B，详见 10.1 | PR 0.6 | 基线降到 0，检查脚本改为要求引用数为 0 |
| L3 桥接代码生成 | 如果契约测试维护成本变高，改为用 `protocol.ts`（或 JSON schema）生成 Swift 的 `BridgeMessage`/`EditorCommand` | 3.5 | 生成物进入 CI 校验（生成后 `git diff --exit-code`） |
| L4 并发现代化 | `VaultService`、`GitSyncEngine` 的 `@unchecked Sendable` + `DispatchQueue` 改为 `actor`；`MainActor.assumeIsolated` 跳转改为 `async`/`await` | 4.3（会话有测试保护） | 不再有 `@unchecked Sendable`（当前 7 处）；场景测试通过 |
| L5 WKWebView 测试类型化 | `tests/webview/*.test.js` 加 `// @ts-check` + JSDoc，或者改写为 TS 后由 `editor-probe` 加载打包产物 | 0.3 | typecheck 覆盖 webview 测试 |
| L6 CI 速度 | 缓存 `.build` 和 `node_modules`；WKWebView 套件复用一次 bundle 构建（`test-web.sh` 已支持） | 1.5 | CI 时长下降并记录 |

### 10.1 L2：未公开文档引用的治理（方案 B）

**目标**：代码、脚本、主题和 CI 配置里的注释都能独立读懂，不依赖仓库外的文档。决策原文继续只留在本地，不公开。

**存量分布**（2026-10-13，共 760 处）：

| 区域 | 数量 | 引用最多的文件 |
|---|---|---|
| `Editor/src` | 286 | `main.ts` 57、`styles/markdown.css` 36、`styles/plume.css` 35、`format-bar.ts` 22 |
| `Sources/Plume` | 197 | `PlumeController.swift` 94 |
| `Sources/PlumeKit` | 111 | `Settings.swift` 24 |
| `Editor/tests` | 110 | `markdown.test.js` 55、`commands.test.js` 32 |
| `Sources/PlumeKitTests` | 36 | |
| `Scripts` | 13 | `smoke/t1.swift`（其中包括那 1 处 `LAB.md`） |
| `.github` | 4 | `ci.yml` |
| `Themes` | 2 | 两个预置主题的第 8 行 |
| `Packaging`（原 `packaging`） | 1 | `plume.rb` |

**节奏**（三条路并行，引用数只减不增）：
1. **护栏**（PR 0.6）：计数棘轮禁止新增引用。
2. **先改对外可见的**（PR 0.1、PR 1.9）：`ci.yml`（4 处）、`Themes/`（2 处）、`packaging/`（1 处）。
3. **改到哪里顺手清到哪里**（阶段 2–4）：一个文件在 PR 中被实质修改（拆分、改名、搬迁、重写）时，在该 PR 末尾追加一个只改注释的提交（`docs(comments): 📝 …`），把整个文件的引用改写掉，并下调基线。重点是 PR 4.2（`NoteSession`）、PR 4.7（`main.ts`）、PR 4.8（`format-bar.ts`）、PR 3.1（`Settings`/`StateStore`）、PR 3.2（`VaultService`）。
4. **专项收尾**（本项）：阶段 4 完成后，按目录批量清理剩余引用，每个 PR 处理一个目录，顺序是 `Sources/PlumeKit` → `Sources/Plume` → `Editor/src`（含 `styles/`）→ `Editor/tests` → `Tests` → `Scripts`。基线降到 0 后删除 `doc-refs.baseline`，脚本改为"发现任何一处就失败"，作为永久护栏保留。

**改写规则**见附录 A.8。改写期间可以在本地维护一份工作底稿 `docs/decision-glossary.md`（编号 → 统一的英文短语），保证同一个编号在不同文件里改写成同样的说法。这份底稿在 `docs/` 下，不会进仓库。

**验收**：
- `check-doc-refs.sh` 要求引用数为 0，并且在 CI 中为绿；
- 每个改写提交只包含注释改动：用 `git diff --word-diff` 抽查，确认没有代码变化，并且 D1 通过；
- 抽查 10 条改写后的注释，由没有决策原文的人阅读，确认能读懂约束和理由。

---

## 11. 风险与应对

| 风险 | 可能性 | 影响 | 应对 |
|---|---|---|---|
| 改名误伤持久化键或主题类名，导致用户数据或主题失效 | 中 | 高 | 第 2 节冻结清单 + 阶段 0 快照测试；`CodingKeys` 保持 raw value |
| 搬迁 `NoteSession` 时引入时序回归（写入、改名、冲突） | 中 | 高 | 先接缝后搬迁、搬迁时原样照搬；smoke t1 + 附录 D；4.3 的 14 个场景锁住行为；dev 构建日常使用 ≥ 3 天 |
| 大规模 `git mv` 导致进行中的分支冲突 | 中 | 中 | 阶段 1 集中在一个短窗口内完成，期间暂停其他功能分支合入；提前通知 |
| SwiftLint 版本漂移导致 CI 突然变红 | 低 | 低 | CI 固定 SwiftLint 版本 |
| esbuild 在目录调整后打包顺序变化 | 低 | 低 | 以功能测试为准，不要求字节一致 |
| 开发版笔记库迁移（PR 1.8）丢失开发笔记 | 低 | 中 | 沿用现有 `migrateDevelopmentVault` 的"staging + 原子移动、绝不合并、源目录保留"规则；本机已知会跳过自动迁移，按 PR 1.8 的说明手工切换一次 |
| 开发版访问 `~/Documents` 反复弹出授权 | 中 | 低 | 现状（checkout 在 `~/Documents` 下）已经是这样，不是新增风险；如果影响开发，可以用固定的本地开发证书签名开发版 |
| 设计素材移动后脚本找不到输入 | 低 | 低 | 仓库内只有 `make-icons.swift` 和 `SettingsForm.swift` 引用 `Design/`，都已列入 PR 1.7；验收时实际跑一次 `make-icons` |
| 注释改写时误改代码，或者丢失理由 | 低 | 中 | 改写提交只含注释，用 `--word-diff` review；只有编号、没有理由的注释按 A.8 第 2 条从 git 历史补全 |

**回滚**：每个 PR 都可以独立 `git revert`。因为持久化格式没有变（JSON 键不变），新版本降级回旧版本后数据仍然可读。

---

## 12. 里程碑与发布节奏

| 里程碑 | 包含 | 发布方式 |
|---|---|---|
| M0 护栏就绪 | 阶段 0 | 不发版（只涉及 CI 和测试） |
| M1 结构整理 | 阶段 1 + 阶段 2 | 合并后发一个 patch 版本，验证打包和公证链路没有受影响 |
| M2 边界纠正 | 阶段 3 | dev 构建日常使用 ≥ 2 天后发 patch 版本 |
| M3 拆分完成 | 阶段 4 | dev 构建日常使用 ≥ 3 天，附录 D 全部通过后发 minor 版本 |

每个里程碑结束时更新附录 C 的度量，并在 `CHANGELOG.md` 中加一条 "Internal: …" 说明（用户不可见）。

---

## 附录 A：命名规范

### A.1 领域词汇表

| 概念 | 统一用词 | 不要用 |
|---|---|---|
| 浮动窗口 | **Panel**（窗口对象叫 `PanelWindow`） | Plume、Pane、Window（泛指时） |
| 一篇笔记 | **Note** | Doc、File（仅指磁盘文件时用 file/filename） |
| 笔记文件夹 | **Vault** | Folder、Library |
| 面板上当前笔记的编辑生命周期 | **Session** | Buffer（buffer 只指文本缓冲） |
| ⌘P | **Switcher** | Picker、Browser |
| ⌘K | **ActionPanel** | Command palette |
| 底部格式栏 | **FormatBar** | Toolbar |
| 外部修改协调 | **Reconcile** | Sync |
| Git/iCloud 同步 | **Sync**（Git 相关加 `GitSync` 前缀） | |
| 版本检查 | **Release**（`ReleaseCheck` / `ReleaseFetcher`） | Update（只用在 UI 文案中） |

**`Plume` 前缀**只用于：模块名（`PlumeKit`）、App 标识（bundle id、日志 subsystem、Info.plist 键）、桥接命名空间（`plumeHost`）、CSS 命名空间（`.plume-*`）。

### A.2 Swift
- 文件名 = 主类型名；extension 文件命名为 `Type+Feature.swift`。
- 一个文件一个主类型。小型辅助类型（< 30 行且属于同一领域）可以放在同一文件。
- 角色后缀的含义：

  | 后缀 | 含义 | 例子 |
  |---|---|---|
  | `Controller` | 拥有窗口或视图（AppKit） | `PanelController`、`MenuBarController` |
  | `Coordinator` | 编排多个服务，不持有视图 | `AppCoordinator`、`VaultCoordinator` |
  | `Service` | 在自己的队列上做异步 I/O | `VaultService` |
  | `Store` | 持有并持久化一个值 | `StateStore`、`SettingsStore` |
  | `Monitor` / `Watcher` | 观察外部来源并发出事件 | `VaultWatcher`、`DockSpaceAssignmentMonitor` |
  | `Policy` | 纯决策函数，无状态 | `SpaceAssignmentPolicy`、`WritePolicy` |
  | `Engine` | 有状态的流程执行器 | `GitSyncEngine` |
  | `Scheduler` | 只负责"什么时候做" | `GitSyncScheduler` |

- 注入用的协议以 `-ing` 结尾（`VaultServicing`、`Scheduling`、`HTTPFetching`）。
- 缩写只用约定俗成的几个：`URL`、`ID`、`CSS`、`JSON`、`L10n`。

### A.3 TypeScript / Editor
- 文件名用 kebab-case；目录按层划分：`bridge/`、`editor/`、`markdown/`、`keyboard/`、`format/`、`ui/`。
- 标识符用 camelCase；DOM 引用以 `El` 结尾（`panelEl`）；模块级常量用 UPPER_SNAKE。
- 模块顶层不产生副作用（`main.ts` 除外）；需要依赖时用 `createXxx(deps)` 工厂注入。

### A.4 CSS
- `.plume-*`（markdown 装饰类）和 `.plume` / `.plume__*`（chrome）属于**主题公开接口**，已冻结；新增装饰类沿用 `.plume-<thing>` 前缀，新增 chrome 元素沿用 `.plume__<element>`，不引入第三种前缀。
- 新增的公开类名必须登记到 `Editor/tests/theme-api.txt`。

### A.5 i18n key
- 格式为 `<界面>.<区域>.<元素>[.<变体>]`，每一段用 camelCase；复数后缀用 `.one` / `.other`（中文可以只提供 `.other`）。
- 界面前缀：`menu`（主菜单）、`menubar`、`editor`（Web 层，构建时打包）、`general` / `appearance` / `shortcuts` / `storage` / `about`（设置页各 tab）、`toast`、`banner`、`error`、`common`。
- 不要为同一个界面开第二个前缀（例如 `shortcut` 与 `shortcuts` 并存）。

### A.6 测试与脚本
- 测试文件命名为 `<Type>Tests.swift`，入口函数为 `run<Type>Tests()`；不要用 `More`、`Misc`、`Extra` 这类名字。
- 脚本用 `verb-noun.sh`（kebab-case）；测试入口以 `test-` 开头；Swift 工具脚本放在 `Scripts/tools/`。

### A.7 持久化名字变更流程
凡是 JSON 键、CSS 公开类名、桥接名、bundle 标识的变更，都必须同时满足：
1. 读取时兼容旧名（解码 fallback）；
2. 写出策略明确（继续写旧名，或者只在 schemaVersion 升级时切换）；
3. 更新快照测试，并在 PR 描述中说明；
4. 在 CHANGELOG 中记录。

### A.9 目录命名

**同一层级内风格一致**；风格跟着该目录所属的生态走，不跨生态统一。

| 区域 | 风格 | 例子 | 原因 |
|---|---|---|---|
| 仓库根目录 | 首字母大写（PascalCase） | `Sources`、`Tests`、`Scripts`、`Design`、`Themes`、`Locales`、`Packaging`、`Artifacts`、`App`、`Editor` | `Sources`、`Tests` 是 SwiftPM 规定的名字，其余向它看齐 |
| `Sources/*`、`Tests/*` 及其子目录 | PascalCase | `Sources/PlumeKit/GitSync`、`Sources/DockSpaceProbe` | 目录名对应模块和领域名 |
| `Editor/` 内部（`src`、`tests`、`bridge`…） | 小写 | `Editor/src/bridge` | npm / TypeScript 惯例 |
| 语言目录 | BCP 47 标识符原样 | `Locales/zh-Hans` | 要与系统的语言标识一致 |
| 平台强制的名字 | 按平台规定 | `.github` | |
| `Scripts/` 内部 | 小写 | `Scripts/tools`、`Scripts/smoke` | 与脚本文件名（kebab-case）一致 |

- **根目录的例外**只有点开头的目录（`.github`）和生成物（`build`、`.build`）；生成物已在 `.gitignore` 里。
- **可执行 target 放在 `Sources/` 下**，不另设根目录 `Tools/`（2026-10-13 把 `Tools/DockSpaceProbe` 移到 `Sources/DockSpaceProbe`）。`Scripts/tools/` 只放脚本，不放 SwiftPM target。
- 在大小写不敏感的文件系统（macOS 默认）上，只改大小写的 `git mv` 要分两步，先改成临时名再改成目标名。

### A.8 注释规范（方案 B）
注释要能独立读懂。理由写在注释里，不引用仓库外的文档。

**禁止出现**（由 `Scripts/check-doc-refs.sh` 检查）：`decision N` / `decisions N`、`design frame 2a` 这类设计稿帧编号、`LAB.md`、`BRIEF.md`。新代码也不要发明新的外部编号体系。设计取舍的讨论写在提交说明或 PR 描述里，注释只保留维护者需要知道的约束和理由。

**改写存量的规则**：
1. **编号后面已经写了理由的**（大多数属于这种）：直接删掉编号，或者换成描述规则的短语。
2. **只有编号、没有理由的**：从上下文、`git log -S 'decision N'`、`git blame` 对应提交的说明里补一句理由。如果维护者本地有决策原文，以原文为准。实在还原不了，就写清楚约束本身以及守护它的测试，例如 "Do not change this to X; `NoteNamingTests` covers it."。
3. **实测数据保留**：只去掉编号，不丢事实。
4. **同一编号用同一种说法**：参考 10.1 里的本地对照表。
5. **语言**：代码注释保持英文，与现有代码一致。
6. **只改注释**：改写提交不包含任何代码改动，也不和功能提交混在一起。

**示例**（取自现有代码）：

| 改写前 | 改写后 |
|---|---|
| `// Decision 76: the name of the thing that happened, and nothing after it.` | `// The banner names what happened and nothing after it.` |
| `/// Decision 10: 500 ms after typing stops, and immediately on dismiss, blur, quit and note switch.` | `/// Writes 500 ms after typing stops, and immediately on dismiss, blur, quit and note switch.` |
| `Decision 13 measured an evicted iCloud note taking **1.862 s** to read` | `An evicted iCloud note was measured taking **1.862 s** to read` |
| `Markdown to a self-contained HTML file — design frame 2a's Export… row.` | `Markdown to a self-contained HTML file — the ⌘K panel's Export… row.` |
| `A theme is a CSS file in this folder (decision 19) — copy it, rename it, edit it.` | `A theme is a CSS file in this folder — copy it, rename it, edit it.` |
| `The traps this is written around are all in LAB.md: the panel is …` | `The traps this is written around: the panel is …` |

---

## 附录 B：检查脚本（供验收使用）

> 说明：git pathspec 不加 `:(glob)` 时，`*` 可以跨目录匹配，所以 `'Sources/*.swift'` 会递归匹配所有子目录。

```bash
# B1 文件名与主类型名一致性：列出顶层类型名与文件名不同的情况（人工复核小型辅助类型）
#    基线（2a1c8ff）输出 40 行
for f in $(git ls-files 'Sources/*.swift'); do
  base=$(basename "$f" .swift); base=${base%%+*}
  grep -hoE '^(public |final |private |fileprivate |@MainActor )*(struct|enum|class|protocol|actor) [A-Za-z0-9_]+' "$f" \
    | awk '{print $NF}' | grep -vx "$base" | sed "s|^|$f: |"
done

# B2 App target 中没有 import 任何 AppKit 系框架的文件（应下沉到 PlumeKit）
#    基线输出：UpdateChecker.swift、VaultService.swift。
#    注意：StateStore.swift 多余地 import 了 AppKit，这个脚本查不出来，需要人工确认。
for f in $(git ls-files 'Sources/Plume/*.swift'); do
  grep -qE '^import (AppKit|WebKit|Carbon|ServiceManagement)' "$f" || echo "$f"
done

# B3 "plume 表示面板" 残留（阶段 2 之后应只剩第 2 节的保留项）；基线命中 93 行
grep -rnE '\b[a-z]+Plume[A-Z]?[a-zA-Z]*|\bplume[A-Z][a-zA-Z]*' Sources Tests Editor/src \
  | grep -vE 'plumeHost|plumeDialect|PlumeKit|pinPlume'

# B4 大文件
git ls-files 'Sources/*.swift' 'Editor/src/*.ts' | xargs wc -l | sort -rn | head

# B5 未公开文档引用数量（PR 0.6 / 10.1）；基线（2a1c8ff）为 760
#    正式检查由 Scripts/check-doc-refs.sh 完成，这里是等价的一行命令
git ls-files -z | grep -zv '^.gitignore$' \
  | xargs -0 grep -IoE '[Dd]ecisions? [0-9]+|[Ff]rames? [0-9]+[a-z]\b|LAB\.md|BRIEF\.md' | wc -l

# B6 设计素材数量（PR 1.7 前后都应为 15）
git ls-files 'Design/*.png' | wc -l
```

---

## 附录 C：基线度量

静态度量为 2026-10-13 在 `2a1c8ff` 上实测。测试度量为阶段 0 完成后（含 PR 0.4 新增的兼容性测试）在 `refactor/architecture` 分支上实测，`Scripts/test-all.sh` 全绿，总耗时 59.8 秒（macOS，本机）。后续阶段的断言数不得低于这里的数字。

测试度量明细：

| 套件 | 断言数 | 备注 |
|---|---|---|
| PlumeKit | 461 个测试 / 3008 | 含 PR 0.4 新增的 5 个兼容性测试 |
| Keyboard tables | 187 个用例 | |
| Theme contract | 46 个公开类 | 另有 1 个已知死选择器 `.plume-line-li`（见 PR 0.4 的发现） |
| Bridge names | 31 个入站消息 / 23 个 host 方法 | |
| Command matrix | 386 | |
| Markdown | 888 | |
| Switcher | 36 | |
| Assign to Desktop | 59 | |
| Narrow panel（380 宽） | 9 | |
| Tooltip | 28 | |
| i18n | 13 | |
| WKWebView 合计 | 1419 | 386 + 888 + 36 + 59 + 9 + 28 + 13 |

| 指标 | 基线 | 阶段 4 目标 |
|---|---|---|
| `PlumeController.swift` 行数 | 2092 | 不存在；`PanelController` ≤ 600 |
| 最大 Swift 文件 | 2092 | ≤ 800 |
| `AppDelegate.swift` | 683 | ≤ 250 |
| `EditorWebView.swift` | 668 | ≤ 400（`BridgeMessage` 移出后） |
| `Editor/src/main.ts` | 1339 | ≤ 300 |
| `Editor/src/format-bar.ts` | 1426 | ≤ 450 |
| Swift 代码量：Plume / PlumeKit / Tests | 8228 / 6237 / 5425 | Plume 下降，PlumeKit 与 Tests 上升 |
| Editor：TS / CSS / 测试 | 8771 / 2895 / 5992 | — |
| PlumeKit 根目录平铺文件数 | 28 | 0 |
| App target 中纯 Foundation 文件 | `VaultService`、`StateStore`（只用 NSLog）、`UpdateChecker`（+ Git 调度逻辑） | 0 |
| 未受检的桥接名称 | 31 个入站 type + 23 个 host 方法 | 0 |
| CI 未运行的测试套件 | 1（i18n） | 0 |
| `@unchecked Sendable` | 7 | 长期项 L4 的目标为 0 |
| 未公开文档引用（B5） | 760 处 / 106 个文件（`decision N` 708、`frame Xy` 51、`LAB.md` 1） | 阶段 1 结束：对外可见文件为 0；阶段 4 结束：明显下降；L2 结束：0 |
| 设计素材 | 15 张图（22 MB）平铺在 `Design/` 和 `Design/Material/`，没有说明 | 15 张全部保留，按 Icons/Explorations 分类，有 README |
| README 未引用的截图 | 5 | 0 |
| 开发版默认笔记库 | `build/Plume-scratch`（`make clean` 需要特殊处理） | `~/Documents/Plume-dev` |
| PlumeKit 测试断言数 | 3008（461 个测试） | ≥ 基线，阶段 3、4 有明显增加 |
| WKWebView 套件断言数 | 1419（7 个套件，明细见上表） | ≥ 基线 |
| smoke t1 通过条目 | 需用户执行：依赖运行中的开发版和终端的 Accessibility 授权，无法在无人值守时运行 | 全部通过 |

---

### 阶段 0–2 结束时的度量（2026-10-13，`refactor/architecture` 分支）

| 指标 | 基线（`2a1c8ff`） | 阶段 2 结束 | 阶段 4 目标 |
|---|---|---|---|
| 最大 Swift 文件 | `PlumeController.swift` 2092 | `PanelController.swift` 2092（只改名，职责拆分在阶段 4） | ≤ 800 |
| `AppDelegate.swift` | 683 | 683 | ≤ 250 |
| `EditorWebView.swift` | 668 | 501（`BridgeMessage` 已拆出） | ≤ 400 |
| `Editor/src/main.ts` | 1339 | 1294（`OutboundMessage` 抽到 `bridge/protocol.ts`） | ≤ 300 |
| `Editor/src/ui/format-bar.ts` | 1426 | 1426 | ≤ 450 |
| Swift 代码量：Plume / PlumeKit / Tests | 8228 / 6237 / 5425 | 8243 / 6284 / 5568 | |
| PlumeKit 根目录平铺文件数 | 28 | 0 | 0 |
| App target 中不依赖 AppKit 的文件 | `VaultService`、`StateStore`（只用 NSLog）、`UpdateChecker` | `VaultService`、`ReleaseFetcher`（`StateStore`/`SettingsStore` 仍 import AppKit，阶段 3 下沉） | 0 |
| 未受检的桥接名称 | 54 | 0（`bridge-names.mjs`） | 0 |
| CI 未运行的测试套件 | 1（i18n） | 0 | 0 |
| 未公开文档引用 | 760 | 746（对外可见文件为 0；基线文件 `Scripts/doc-refs.baseline`） | 明显下降，L2 清零 |
| B1 文件名与类型名不一致 | 40 | 14（均为小型辅助类型） | — |
| B3 "plume 表示面板"残留（Swift） | 93 | 0 | 0 |
| PlumeKit 测试 | 约 456 个测试（推算：阶段 0 记录的 461 减去 PR 0.4 新增的 5 个，未实测）/ 断言数未记录 | 463 个测试 / 3014 断言 | ≥ 此值 |
| WKWebView 套件断言 | 1419 | 1419 | ≥ 此值 |
| `@unchecked Sendable` | 7 | 7 | L4 目标为 0 |

### 阶段 3 结束时的度量（2026-10-13，`refactor/architecture` 分支）

| 指标 | 阶段 2 结束 | 阶段 3 结束 | 阶段 4 目标 |
|---|---|---|---|
| `GitSyncController.swift` | 255 | 42 | ≤ 80 |
| `EditorWebView.swift` | 501 | 460 | ≤ 400 |
| `PanelController.swift` | 2092 | 2076（`call("…")` 换成 `send(.…)`） | ≤ 600 |
| `AppDelegate.swift` | 683 | 683 | ≤ 250 |
| Swift 代码量：Plume / PlumeKit / Tests | 8243 / 6284 / 5568 | 7019 / 8007 / 6733 | Plume 继续下降 |
| App target 中只 import Foundation 的文件 | 2 | 0 | 0 |
| `editor.call("…")` 调用点 | 约 45 | 0 | 0 |
| 未受检的桥接名称 | 0（`bridge-names.mjs`） | 0（`BridgeContractTests`，名称、参数个数、字段） | 0 |
| PlumeKit 测试 | 463 个测试 / 3014 断言 | 528 个测试 / 3301 断言 | ≥ 此值 |
| WKWebView 套件断言 | 1419 | 1419 | ≥ 此值 |
| 未公开文档引用 | 746 | 746（新增的文件没有引入新引用） | 明显下降，L2 清零 |
| `@unchecked Sendable` | 7 | 7 | L4 目标为 0 |

### 阶段 4 结束时的度量（2026-10-13，`refactor/architecture` 分支）

| 指标 | 阶段 3 结束 | 阶段 4 结束 | 目标 |
|---|---|---|---|
| `PanelController.swift` | 2076 | 493（+ 6 个 extension 文件，合计 1178） | ≤ 600 |
| `AppDelegate.swift` | 683 | 28（+ `AppCoordinator` 384） | ≤ 250 |
| `NoteSession.swift` | — | 702（+ `+External` 248） | ≤ 800 |
| `Editor/src/main.ts` | 1283 | 260 | ≤ 300 |
| `Editor/src/ui/format-bar.ts` | 1426 | 353 | ≤ 450 |
| 最大 Swift 文件 | 2076 | 702 | ≤ 800 |
| Swift 代码量：Plume / PlumeKit / Tests | 7019 / 8007 / 6733 | 6336 / 9142 / 7821 | Plume 继续下降 |
| PlumeKit 测试 | 528 个测试 / 3301 断言 | 577 个测试 / 3475 断言 | ≥ 此值 |
| 键盘表用例 | 187 | 328 | ≥ 此值 |
| WKWebView 套件断言 | 1419 | 1419 | ≥ 此值 |
| `NoteSession` 场景测试 | — | 40 | ≥ 14 |
| SwiftLint 长度阈值（error） | 2200 / 1000 / 140 | 800 / 450 / 100 | 1000 / 700 / 150 |
| 未公开文档引用 | 746 | 734 | 明显下降，L2 清零 |
| `@unchecked Sendable` | 7 | 7 | L4 目标为 0 |

---

## 附录 D：手工回归清单

标记 🧪 的 PR 合入前，执行与改动相关的条目；里程碑 M2 和 M3 执行全部条目。

1. ⌃⌥Space 召唤和隐藏；面板失焦后再按一次是**重新聚焦**而不是隐藏。
2. ⌘N 后输入标题，停顿 500 ms：文件出现，文件名跟随首行变化；切走或隐藏后文件名定稿。
3. ⌘N 后什么都不输入就切走：不会留下空文件。
4. 用外部编辑器修改当前笔记：面板内容更新，光标保留。
5. 外部和面板同时修改：生成冲突副本，出现黄色 banner，面板继续编辑副本。
6. 输入后立即 ⌃X：Recently Deleted 中是最新内容，可以恢复，恢复后自动打开。
7. 输入后立即 ⌘D：出现 toast，副本包含还没落盘的文字，并且副本的文件名跟随标题。
8. ⌘P：搜索（模糊和全文）、置顶、切换；⌘[ / ⌘] 前进后退。
9. ⌘K 各行：Assign to Desktop 三种状态（包括 Dock 接管时显示的系统管理状态）、Keep on Top、Hide from Capture、Export、Copy as Markdown、Rename、Settings。
10. 设置窗口：切换语言即时生效（设置窗口会重建）、切换主题、录制快捷键；手工编辑 `settings.json` 即时生效。
11. Git 同步：Sync Now；冲突标记出现时菜单栏显示黄点，移除标记后恢复同步；失败时显示红点。
12. 多桌面和全屏 App 上召唤；外接显示器拔插后，面板仍在可达的位置。
13. （条件允许时）打开被 iCloud 驱逐的笔记：显示 downloading banner，下载期间的输入不丢。
14. 输入后立即退出：重新启动后内容完整，光标位置正确。
15. 自定义主题（复制 `Compact.css` 修改后启用）：样式正常生效。

---

## 附录 E：实施中发现、尚未处理的问题

这些是实施阶段 0–2 时顺带发现的**既有问题**。按"重构不改行为"的原则没有在重构 PR 里修，需要单独决定是否处理。

| # | 问题 | 位置 | 影响 | 建议 |
|---|---|---|---|---|
| 1 | 预置主题 Compact.css 的 `.cm-line.plume-line-li { text-indent: -14px; }` 是死选择器：编辑器只生成 `plume-line-li-1` … `-4`，从不生成 `plume-line-li`，这条规则匹配不到任何元素。该文件由改名 Pane→Plume 时的全局替换带入 | `Themes/Compact.css:27`；已登记在 `Editor/tests/theme-contract.mjs` 的 `KNOWN_DEAD` | Compact 主题的列表悬挂缩进没有按作者的意图生效 | 单独一个 `fix`：确认意图后改成 `plume-line-li-1…4` 或删除，同时删掉 `KNOWN_DEAD` 里的条目 |
| 2 | 测试产物进入发布包：`Editor/tests/unit/run.mjs` 把编译后的测试写到 `Editor/dist/unit/`，而 `Scripts/build-app.sh` 把整个 `Editor/dist/` 拷进 app。只要先跑过按键表测试再打包（CI 就是这个顺序），9 个 `*.test.mjs` 就会进入 `Plume.app/Contents/Resources/Editor/unit/` | `Editor/tests/unit/run.mjs:21`、`Scripts/build-app.sh` | 发布包里多了不会被使用的测试文件；基线构建里就已存在 | 把单测输出目录改到 `Editor/.test-build/`（已被 `.gitignore` 的思路覆盖，需补一行），或在 `build-app.sh` 里只拷 `index.html` |
| 3 | `markdown.css` 中 `.plume-raw` 和 `.plume-codeblock` 有样式，但源码里没有任何地方生成这两个类 | `Editor/src/styles/markdown.css:816-817` | 死 CSS，无可见影响 | 确认后删除 |
