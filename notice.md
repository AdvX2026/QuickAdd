# notice — QuickAdd 根目录

面向下一位 agent 的持久信息。设计与产品规格在 `PRD.md`，通用工作规则在 `AGENTS.md`。

## 构建与测试

Xcode 工程在 `QuickAdd/QuickAdd.xcodeproj`，deployment target **iOS 26.5**。

```bash
xcodebuild -project QuickAdd/QuickAdd.xcodeproj -scheme QuickAdd \
  -destination 'platform=iOS Simulator,id=<UDID>' test
```

**坑：不能用 `simctl list devices` 里随便一台。** 那份清单包含旧 runtime 的机型（iPhone 16 系列），deployment target 是 26.5，选中会报一个指向 visionOS 的误导性错误。用这条命令挑：

```bash
xcodebuild -project QuickAdd/QuickAdd.xcodeproj -scheme QuickAdd -showdestinations
```

只有 `OS:26.5` 的条目可用（iPhone 17 系列 / iPhone Air / iPad 各型号）。

## 工程结构

**工程使用 `PBXFileSystemSynchronizedRootGroup`** —— 往 `QuickAdd/QuickAdd/` 下新建 `.swift` 文件会自动纳入编译，**不需要改 `project.pbxproj`**。

但**新增 Info.plist 键仍需改 pbxproj**：工程用 `GENERATE_INFOPLIST_FILE`，权限文案等以 `INFOPLIST_KEY_*` 形式写在 build settings 里，Debug 和 Release 两套配置都要加。

同步文件夹的另一面：**非源码文件会被当成资源打进 App bundle**。往 `QuickAdd/QuickAdd/` 下放 `notice.md` 时踩到过，已用 `EXCLUDED_SOURCE_FILE_NAMES = "*.md"`（两套配置都加了）挡掉，新增 `.md` 不用再管。放其他类型的非源码文件前，先构建后确认一下 bundle 里没有它：

```bash
ls <DerivedData>/Build/Products/Debug-iphonesimulator/QuickAdd.app
```

写代码时 SourceKit 常报 "Cannot find type X in scope"，那是索引滞后于新建文件，**以 `xcodebuild` 结果为准**。

## 密钥

API Key 有两个来源，都不进版本库：

- **App 运行时**：Keychain（`KeychainStore`，service `cn.Teethe.QuickAdd`），设置页录入
- **Spike 脚本**：`secrets/deepseek.key` 或环境变量 `DEEPSEEK_API_KEY`

`.gitignore` 已覆盖 `.env*`、`secrets/`、`*.key`、`Spike/out/`。任何时候都不要打印、日志或回显 key。

## Spike

`Spike/deepseek-probe.swift` 是独立于 App 的验证脚本，**在仓库根目录**执行：

```bash
swift Spike/deepseek-probe.swift --no-thinking
```

用途：改提示词后快速验证抽取质量，不用起 App。脚本的提示词逐节镜像 `PromptBuilder`，**两边结构必须保持一致**——结构漂了，spike 就预测不了 App 行为，也就失去意义。

### 日历定义存在三个地方

| 位置 | 角色 |
|---|---|
| `Spike/deepseek-probe.swift` 顶部 `eventCalendars` | spike 用的版本 |
| `Settings/CalendarSetup.eventDefinitions` | App 用的版本，首次读取日历时自动写入设置 |
| `PromptBuilder.calendarSection()` | 只负责渲染，不含定义本身 |

前两处内容必须一致，**都在版本库里，可以直接 diff**。改定义的流程：先在 spike 里改并验几次 → 验稳了同步到 `CalendarSetup`。

为什么定义要硬编码在 App 代码里、以及日后上架要怎么改，见 `QuickAdd/QuickAdd/Settings/notice.md`。

设置页里的说明一旦手工改过就不会被种子覆盖，所以排查归类问题时要读设备上的真实配置：

```bash
plutil -p ~/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/\
Application/*/Library/Preferences/cn.Teethe.QuickAdd.plist
```

### 定义的写法：给判定标准，不要只举例

这是踩过的坑。早期版本里「工作」只列了三个例子、「创意」以「任何创意类」开头，结果例子之外的工作内容全被创意吸走，`过 Q3 方案` 三次只对一次。

改成每条都带一句可执行的判断后（如「有没有他人在等这件事的结果」「在输入还是在产出」），9 次运行归类完全一致。写新定义时照这个格式。

### 已测基线（2026-08-06，`deepseek-v4-flash`，thinking 关闭）

- 延迟 3.1–4.1s，单次约 $0.0002
- 归类稳定性 9/9
- **抽取完整性 8/9** —— 约 1/9 的概率会漏抽一个条目。这比归类错更隐蔽，用户不会知道自己漏了什么。目前无对策，出现时不要当成新 bug
- 深夜使用时「今天上午」存在歧义：凌晨 2 点说「今天上午十点做了X」，模型可能理解为前一天

详见 `Spike/README.md`。

## 代码地图

```
QuickAdd/QuickAdd/
  QuickAddApp.swift          SwiftData 容器 + 环境注入
  CaptureCoordinator.swift   编排：落盘 → 抽取 → 校验 → 审阅 → 写入
  Models/                    CaptureSession、DraftItem（SwiftData）
  Extraction/                schema、校验层、提示词组装、provider
  Calendar/                  EventKit 封装、写入格式
  Settings/                  设置、Keychain
  Views/                     SwiftUI
```

## 几条不该被"顺手优化"掉的约束

- **`rawText` 必须在调 LLM 之前落盘**（`CaptureCoordinator.submit`）。这是"不丢记录"的唯一实现点
- **提示词的静态段和动态段必须是两条独立 message**。拼成一条会让上下文缓存命中率归零（实测 0/856 vs 896/1018）
- **静态段必须含 "json" 字样和 schema 示例**。缺了会让 `json_object` 模式输出空白直到耗尽 token
- **解析层的容错是刻意的**：`ExtractionResponse` 每个字段都可选、数组逐元素跳过失败项。`json_object` 只保证语法合法，不保证结构
- **校验层不许让抽取失败**，只标黄（`DraftItem.flag`）。唯一丢弃的情况是标题为空
- **日历标题只在单个账户内唯一**。多账户同名时两个一起退出流水线（`CalendarSetup.usable`），绝不任选一个 —— 那会把私人回记静默写进同事可见的日历。详见 `Settings/notice.md`
- 时间推算的三条提示词规则（`PromptBuilder`）都是实测缺陷倒推出来的，改动前先跑 spike 复验
