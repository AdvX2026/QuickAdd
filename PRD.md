# QuickAdd（闪记）产品规格

> 状态：设计中 · 最后更新 2026-08-05
> 本文是产品与技术设计的单一来源。实现约定见 `AGENTS.md`。

## 1. 产品定义

把一段模糊的自然语言（口述或打字）转成结构化的日历事件与提醒事项，写入 iOS 系统日历/提醒。

与常规日程 App 的关键差异是**双向**：

- **规划（future）**：记录将要做的事
- **回记（past）**：把已经做完的事补写进日历，作为可回溯的档案

两者共用同一批语义日历，不单独分离。

**平台**：iOS 26+，SwiftUI，Liquid Glass。不考虑其他平台。

---

## 2. 里程碑

| 阶段 | 范围 |
|---|---|
| **M0** | 文本输入 → LLM 抽取（含日历归类）→ 可编辑草稿卡片 → 按格式规范写入对应日历/提醒列表 → SwiftData 全程留痕。设置页：模型配置、日历语义说明、格式规范 |
| **M1** | 语音输入：`SpeechAnalyzer` + `SpeechTranscriber` 实时转写、文字上推动画、修改/发送 |
| **M2** | 冲突检测：Swift 粗筛 + LLM 精判 + 合并/替换/删除 UI |
| **M3** | `clarifications` 追问、Action 按钮 App Intent、Share Extension |

**为什么 M0 不含语音**：抽取质量决定这个 App 成不成立。先用文本把 prompt 调稳，避免"到底是转写错了还是理解错了"的调试地狱。

**为什么冲突检测排在语音之后**：它是复杂度最高的一块，且价值依赖于日历里已积累了 QuickAdd 的记录——冷启动阶段冲突场景很少。

---

## 3. 核心概念

### 3.1 direction（时间方向）

每条抽取结果带 `direction: past | future`。

- **只用于**：时间合理性校验、冲突检测触发
- **不用于**：决定写入哪个日历

### 3.2 calendar（语义日历）

用户已有的日历分类习惯（创意 / 工作 / 生活 / 个人 …）。回记与规划**共用**这批日历。

LLM 输出**日历名称字符串**，不输出 `calendarIdentifier`——UUID 类字符串 LLM 抄错率高。名称到 identifier 的映射在 Swift 侧完成。

### 3.3 冲突的三种类型（M2）

| 类型 | 场景 | 处理 |
|---|---|---|
| **A. 同一件事的两个副本** | 计划「周三 15:00 和张三开会」，实际开了，回记「周三下午和张三聊了两小时」 | 建议**更新原事件**（时间改为实际值，附注补充），而非新建 |
| **B. 幽灵计划** | 计划「周三 15:00 健身」，没去；回记「周三下午在家躺着」 | 提示冲突，询问是否删除或标记未完成 |
| **C. 时间重叠但不同事** | 计划「15:00 开会」，回记「15:00–16:00 写代码」 | 仅提示，**不建议任何自动动作** |

判定核心是"是否同一件事"，纯时间比对无法解决（计划 15:00、实际 15:30 开始，时间对不上），必须语义判断。

**硬底线**：LLM 只产出建议，所有对已有日历数据的修改/删除必须经用户在 UI 上显式确认。绝不自动删除。

---

## 4. 数据模型（SwiftData）

```
CaptureSession
  id: UUID
  createdAt: Date
  sourceKind: .text | .voice          // M0 仅 .text
  rawText: String                     // 原始输入 / 转写结果
  audioFileURL: URL?                  // M1
  status: .draft | .extracting | .reviewing | .committed | .failed
  llmRawResponse: String?             // 原始响应留存，调 prompt 时的依据
  modelId: String?                    // 本次使用的模型
  errorMessage: String?
  items: [DraftItem]

DraftItem
  id: UUID
  kind: .event | .reminder
  title: String
  emoji: String?
  details: String                     // 附注模板中的 {details}
  calendarName: String                // LLM 输出的名称
  resolvedCalendarID: String?         // Swift 映射结果，nil 表示映射失败
  startDate: Date?
  endDate: Date?
  dueDate: Date?                      // reminder 用
  isAllDay: Bool
  direction: .past | .future
  needsConfirmation: Bool
  confirmReason: String?
  isSelected: Bool
  committedIdentifier: String?        // EKEvent/EKReminder identifier，幂等依据
```

**铁律**：`rawText` 必须在调用 LLM **之前**落盘（`status = .draft`）。这是"不能丢记录"的唯一实现点。崩溃、断网、API 报错均不丢原始输入。

---

## 5. LLM 契约

### 5.1 System prompt 结构（顺序固定，不可调整）

按此顺序拼装，以最大化 DeepSeek 的上下文缓存命中率：

```
① 静态段（每次完全一致，吃缓存）
   - 角色限定：只做日程/提醒抽取，不闲聊、不给建议、不做全能助手
   - event / reminder 分流规则
   - direction 判定规则
   - 日历语义说明（来自设置，含边界反例）
   - 格式规范说明（emoji、details 写法）
   - JSON schema 定义与示例
   - 禁止项

② 动态段
   - 当前时间（ISO8601）、时区、星期几、本周一日期

③ 用户输入
```

静态段约 800–1500 token，天天不变。**调整拼装顺序会打掉缓存，需谨慎。**

### 5.2 关键规则

**event vs reminder 分流**
- 有明确时间点/时间段，或叙述已发生 → **event**
- 只有截止日或无时间的待办 → **reminder**

**direction 判定**
- 过去时态叙述、已完成语气 → `past`
- 未来意图、计划语气 → `future`

**禁止项**
- 禁止输出相对时间词（"明天"、"下周"），一律 ISO8601 带时区偏移
- 禁止输出重复规则（RRULE），只输出单次事件
- 禁止编造原文没有的细节
- 无可抽取内容时返回空数组，不许硬凑

**日历归类**
- 必须从给定的日历名称列表中选择，不得自创
- 无法判断时使用设置中指定的默认日历

### 5.3 输出 schema

```jsonc
{
  "events": [
    {
      "title": "过 Q3 方案",
      "emoji": "📊",
      "details": "与张三讨论 Q3 方案细节，约一个半小时",
      "calendar": "工作",
      "start": "2026-08-05T10:00:00+08:00",
      "end":   "2026-08-05T11:30:00+08:00",
      "allDay": false,
      "direction": "past"
    }
  ],
  "reminders": [
    {
      "title": "交周报",
      "emoji": "📝",
      "details": "",
      "calendar": "工作",
      "due": "2026-08-06T18:00:00+08:00",
      "direction": "future"
    }
  ],
  "clarifications": []
}
```

`clarifications` **从第一版就保留在 schema 中**（M0 恒为空数组），M3 启用时是纯增量改动。其结构：

```jsonc
{ "id":"c1", "kind":"choice|text", "question":"…", "options":[…], "affects":["e2"] }
```

### 5.4 Swift 校验层（LLM 之后、UI 之前）

| 情况 | 处理 |
|---|---|
| JSON 解析失败 | `status = .failed`，**原文保留**，UI 提供「重试」 |
| `calendar` 不在白名单内 | 落默认日历 + 标 `needsConfirmation` |
| `direction=past` 但时间在未来（或反之） | 标 `needsConfirmation` |
| 时间超出 `now ± 1 年` | 标 `needsConfirmation` |
| `end < start` | 自动修正为 `start + 1h` + 标 `needsConfirmation` |
| `title` 为空 | 丢弃该条 |

**校验失败一律不报错**，只把卡片标黄让用户点一下改。

---

## 6. 日历与写入规范

### 6.1 日历语义说明

设置中为每个可写日历填写定义。**必须包含边界反例**——只写正例时 LLM 在边界上准确率明显下降：

```
个人：健康就医、理财、证件办理、个人成长。
      不包括 → 和朋友的活动（→生活）、公司组织的体检（→工作）
创意：写作、设计、副业项目、灵感记录。
      不包括 → 工作范围内的创意任务（→工作）
```

### 6.2 日历列表的工程细节

| 细节 | 处理 |
|---|---|
| 用户重命名日历 | 设置中同时持久化 `calendarIdentifier` + `title`；identifier 失效时按 title 回退匹配；均失效则提示重新配置 |
| 订阅日历（节假日、赛程等） | `allowsContentModifications == false`，设置页列表**必须过滤**，否则写入静默失败 |
| 提醒事项列表 | Reminders 的 list 同样是 `EKCalendar`，按同一套机制处理 |

### 6.3 写入格式

**标题**：`"\(emoji) \(title)"`。emoji 由 LLM 按内容生成（单独字段，非拼在 title 内），设置中可全局关闭。

**附注**：占位符模板（字符串替换，非模板引擎），设置中可编辑。默认：

```
{details}

—
由 QuickAdd {app_version} 于 {timestamp} 记录，模型 {model}
```

支持占位符：`{details}` `{app_version}` `{timestamp}` `{model}` `{session_id}`。
`{app_version}` 从 `CFBundleShortVersionString` 读取，不硬编码。

**溯源 URL**：同时写入 `EKEvent.url = quickadd://session/<uuid>`。一个字段解决三件事：

1. **幂等** — 重复提交时可靠识别已创建项
2. **冲突检测（M2）** — 区分"QuickAdd 创建"与"其他来源"，两者处理策略不同
3. **反向跳转** — 从日历点回 QuickAdd 查看原始记录

附注中的 `{session_id}` 作为 url 字段不同步时的兜底。

---

## 7. 模型接入

**单一 `OpenAICompatibleProvider`**，不为每个模型写独立实现。DeepSeek 使用 OpenAI 兼容的 `/chat/completions`，配置三项即可切换模型：

```
baseURL  +  apiKey（Keychain）  +  modelId
```

覆盖 DeepSeek / OpenAI / Moonshot / 硅基流动 / OpenRouter / 本地 Ollama。设置页提供若干 preset 一键填充 baseURL。

**当前目标模型**：DeepSeek（型号待确认，见 §12）。

---

## 8. 权限

| 权限 | API | 请求时机 |
|---|---|---|
| 日历 | `requestFullAccessToEvents()` | 首次进入设置页配置日历映射时 |
| 提醒事项 | `requestFullAccessToReminders()` | 同上 |
| 麦克风 + 语音识别 | M1 | 首次录音时 |

**需要完整读权限**（而非只写），因为要枚举日历列表、并在 M2 读取已有事件做冲突检测。授权文案须说明读取用途。

---

## 9. 界面

**主屏**：中部欢迎语/提示语，底部 Liquid Glass 输入条。M0 只有文本输入 + 发送，但**布局按最终形态预留语音按钮位置**，M1 直接填入。

**草稿审阅**：卡片列表。每张卡片可勾选、编辑（标题/emoji/时间/日历/附注）、删除。`needsConfirmation` 的卡片标黄并显示原因。底部「添加所选 (n)」。

**日志**：session 列表 → 详情（原始输入 / 抽取结果 / 已写入哪些 / 模型与耗时）。

**设置**：模型配置、日历映射与语义说明、提醒列表映射、格式规范。

**导航**：导航栏左上 → 日志，右上 → 设置（sheet）。

> **不采用左滑抽屉侧边栏**：与系统左边缘返回手势冲突，非 HIG 推荐的 iPhone 模式，且仅两个入口不值得。

---

## 10. M0 验收标准

输入：

> 今天上午十点跟张三过了下 Q3 方案，聊了一个半小时。下午三点做了牙齿检查。明天要交周报，周五之前把机票订了。下周一早上九点有个部门例会。晚上想写写那个短篇小说的开头。

期望输出：

| 类型 | direction | 时间 | 日历 | 检验点 |
|---|---|---|---|---|
| event | past | 今天 10:00–11:30 | 工作 | 时长推算 |
| event | past | 今天 15:00 | 个人 | |
| event | future | 今天晚上 | 创意 | 模糊时段处理 |
| event | future | 下周一 09:00 | 工作 | 相对日期 + 星期推算 |
| reminder | future | 明天 | 工作 | event/reminder 分流 |
| reminder | future | 周五前 | 生活 or 个人 | ⭐ **边界模糊项，专用于验证语义说明是否生效** |

「订机票」的归属应完全由设置中的边界定义决定。若归属漂移不定，说明语义说明的写法需要调整。

---

## 11. 明确不做

- 读取「语音备忘录」App 的录音 —— **技术上不可行**，其数据位于私有容器，无公开 API 或 entitlement
- 重复事件（RRULE）
- 完整的 tool-calling agent loop —— 追问降级为结构化输出中的 `clarifications` 字段
- 左滑抽屉侧边栏
- iOS 之外的平台
- 跨时区处理 —— 统一使用设备当前时区

---

## 12. 待确认

- [ ] DeepSeek 目标模型的准确 `modelId` 字符串
- [ ] DeepSeek `baseURL`
- [ ] 是否支持 `response_format: {"type":"json_schema"}`（可强约束 schema），还是仅 `{"type":"json_object"}` —— 决定 prompt 中 schema 示例的详细程度与解析容错强度
- [ ] M2 冲突判定为"同一件事"时的默认动作：合并更新原事件 / 保留两条 / 每次询问

---

## 13. 测试策略

按 `AGENTS.md` 的 **lightweight tool** profile，不建重型测试架子。两处例外必须有单元测试：

1. **JSON 解析与容错**
2. **校验层规则**（§5.4 全表）

理由：纯函数、易测、且是最容易产生静默错误的位置。UI 与 EventKit 写入以手动验证为主。
