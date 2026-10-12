# Dock 桌面分配检测

Dock 分配只读检测，不改写系统偏好或 Plume 的 `spaceAssignment` / `assignedSpace`。明确的系统分配优先生效，同时控制菜单、窗口集合行为和唤出时的桌面判断。

## 状态来源

检测读取当前用户的 `~/Library/Preferences/com.apple.spaces.plist`，按应用的 bundle identifier 查询 `app-bindings`。本机已观察到字符串 `AllSpaces` 和桌面 UUID 两种值；正式版 `com.tiylabs.plume` 与开发版 `com.tiylabs.plume.dev` 分开查询。

| 读取结果 | 检测状态 |
| --- | --- |
| 有效 `app-bindings` 字典内没有该应用 | `unassigned` |
| 值为 `AllSpaces` | `everySpace` |
| 值为合法 UUID | `oneSpace:<UUID>` |
| 文件不可读、数据损坏、字典缺失、值无法识别 | `unknown:<reason>` |

桌面 UUID 仅表示保存的系统分配，不保证对应桌面仍然存在。⌘K 的显示编号交由 `Spaces.desktop(uuid:)` 解析；无法解析时显示「指定桌面」，不将它误判为无分配。

这个格式未公开，不应把缺少整个字典、陌生格式或读取失败当作取消分配。直接读取文件绕过应用自身的 UserDefaults 缓存，但 Dock / cfprefsd 的落盘可能滞后；检测结果不等于 WindowServer 已经完成窗口调整。

## 运行时刷新

应用启动时开始检测；应用激活、系统唤醒、桌面切换、唤出窗口和打开 ⌘K 时请求刷新。由于没有公开的 Dock 分配变更通知，运行期间还每两秒读取一次。文件读取在后台执行，同一时刻只允许一次读取；只在结果变化时记录统一日志。

日志 subsystem 为当前 bundle identifier，category 为 `DockSpaces`。检测结果同时送到 ⌘K：系统有明确分配时，主行显示「桌面分配：桌面 N」或「桌面分配：全部桌面」，不显示副标题。展开后的三项全部禁用，系统结果对应项勾选，并在该项标注来源：「当前桌面（桌面 N，由系统分配）」或「全部桌面（由系统分配）」。鼠标不能点击，键盘导航跳过禁用项，Swift 消息入口也拒绝分配操作。

底部说明为「无法在当前菜单中操作，请在Dock中右键Plume操作分配桌面」。未知与检查中只在展开时显示说明。

菜单打开期间收到新结果会实时刷新，保留搜索和滚动位置；如果当前选中项变为禁用，选择回到桌面分配主行。系统取消分配后恢复 Plume 偏好的标签、勾选及可操作状态。系统无分配时不显示额外说明。

`SpaceAssignmentPolicy` 统一生效策略：Dock 指定桌面时清除 `.canJoinAllSpaces` 并使用系统桌面 UUID；Dock 全部桌面时启用该标志。系统策略变化后，现有面板退出并重新进入窗口列表，让 macOS 重新应用 Dock 绑定，保留窗口、文档与停放位置。暂时读取失败时维持上一次明确的系统策略；确认取消系统分配后恢复 Plume 保存的偏好。

## 独立诊断

在项目根目录执行，默认同时查询正式版和开发版：

```sh
swift run DockSpaceProbe
```

连续观察开发版的分配变化（Ctrl-C 结束）：

```sh
swift run DockSpaceProbe --bundle com.tiylabs.plume.dev --watch
```

命令逐行输出 JSON，包括检查时间、应用标识、检测状态和偏好文件路径。连续观察只在状态变化时输出。单次检查返回 0 表示所有查询均识别成功，1 表示至少一项为未知，2 表示参数或输出错误。

可用独立 plist 验证解析与连续刷新，不操作系统配置：

```sh
swift run DockSpaceProbe --bundle com.tiylabs.plume.dev --preferences /tmp/dock-space-fixture.plist --watch
```

## 真机验证

使用开发版，并从当前状态开始：

1. 开启开发版 Dock 图标，运行上述 `--watch` 命令。
2. 在 Dock 菜单依次选择「全部桌面」「此桌面」「无」，核对输出是否依次变为 `everySpace`、`oneSpace:<UUID>`、`unassigned`。记录实际刷新延迟。
3. 对「此桌面」的 UUID，核对系统的桌面数据是否包含它；切换、重排桌面后 UUID 应保持对应关系。
4. 保留分配并隐藏 Dock 图标，检测仍应报告系统绑定；隐藏图标不代表取消分配。
5. 重启开发版，检测应恢复相同的系统绑定；正式版状态不应被开发版操作影响。
6. 覆盖多显示器、全屏空间、删除所分配桌面和系统唤醒，并记录原始绑定值是否出现其他格式。

单元测试验证解析边界、两种 plist 编码、原子替换后重新读取及读取不改写文件。实际 Dock 操作的落盘延迟与不同系统版本兼容性需要真机确认。策略测试覆盖应用全部桌面切换到 Dock 指定桌面、所有应用/系统选择组合、读取失败及取消恢复。

## 已完成验证

- `swift build --product Plume` 和 `swift build --product DockSpaceProbe` 通过。
- `bash Scripts/test.sh`：456 项测试、2987 个断言全部通过，包含系统优先策略及读取失败/取消恢复测试。
- 本机正式版和开发版均检测为 `unassigned`；有效绑定字典内没有这两个应用。
- 本机已有的其他应用绑定分别被诊断工具识别为 `oneSpace` 和 `everySpace`；UUID 绑定与系统保存的桌面配置匹配。验证输出不列出其他应用标识。
- 使用临时 plist 连续验证 `unassigned → everySpace → oneSpace → unassigned → unknown:invalidPropertyList → everySpace`，每次原子替换均被捕获，损坏后恢复读取成功。
- ⌘K 系统分配菜单调整后，TypeScript 类型检查与应用编译通过；真实 WKWebView 中桌面分配测试在 460pt / 340pt 宽度各通过 59 个断言，380pt 窄窗口测试通过 9 个断言，语言切换测试通过 13 个断言。覆盖主行无系统来源标注、无副标题、三项禁用、系统结果对应项勾选及来源标注、鼠标不触发、键盘跳过、检测实时更新、取消后恢复操作、中英文及文字换行。
- 使用本机已存在的开发版 Dock 桌面 1 绑定，对真实 `PlumePanel` 先启用全部桌面，再执行策略切换：确认 `.canJoinAllSpaces` 被移除，同一个窗口与停放位置保持，SkyLight 读取的实际归属为桌面 1，UUID 与系统绑定一致。
- 未操作实际 Dock 菜单，尚未测量其偏好落盘延迟；未测试其他 macOS 版本。
