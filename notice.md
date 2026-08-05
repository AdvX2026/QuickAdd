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

用途：改提示词后快速验证抽取质量，不用起 App。日历定义硬编码在脚本的 `staticPrompt` 里，与 App 的设置页是两套，**调完要手动同步到 `PromptBuilder`**。详见 `Spike/README.md`。

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
- 时间推算的三条提示词规则（`PromptBuilder`）都是实测缺陷倒推出来的，改动前先跑 spike 复验
