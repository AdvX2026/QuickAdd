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
| **M2** | 冲突检测：按回记范围粗筛 + LLM 精判 + 来源约束 + 合并/标记未执行 UI（见 §7） |
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

### 3.3 事件来源（origin）

已有日历事件在冲突处理中必须先判定来源。详见 §7。

| 来源 | 判定依据 |
|---|---|
| `plan` | 识别号存在且 `d=future`；或用户手动标注为计划 |
| `recap` | 识别号存在且 `d=past`；或用户手动标注为回记 |
| `unknown` | 无识别号且无标注 |

**用户会在日历 App 中手动创建回记**，因此「无识别号的过去事件」不能推定为计划。

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
  // —— M2 ——
  recapRange: DateInterval?           // 本次回记覆盖的时间范围
  conflictStatus: .notApplicable | .pending | .resolved | .skipped | .failed
  proposals: [ConflictProposal]

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

// —— M2 ——
ConflictProposal
  id: UUID
  targetEventIdentifier: String       // 已有事件的 EKEvent.eventIdentifier
  targetSnapshot: String              // 标题+时间快照，执行前比对，防外部并发修改
  origin: .plan | .recap | .unknown   // 见 §3.3
  action: .merge | .markMissed | .delete | .keep
  reason: String                      // LLM 给出的理由，必填，直接展示给用户
  linkedDraftItemID: UUID?            // merge 时指向哪条回记
  isAccepted: Bool                    // 用户是否勾选
  appliedAt: Date?

EventOriginTag                        // 用户手动标注的来源，零侵入本地表
  eventIdentifier: String             // 主键
  origin: .plan | .recap
  taggedAt: Date
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

约束理由是**首字延迟**而非成本（见 §8.5）。另需保证静态段始终包含 "json" 字样与 schema 示例——这是 `json_object` 模式的硬性要求（见 §8.3）。

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
  "recap_range": {
    "start": "2026-08-05T00:00:00+08:00",
    "end":   "2026-08-05T23:59:59+08:00"
  },
  "clarifications": []
}
```

`recap_range` 是本次回记覆盖的时间范围，供 M2 冲突检测粗筛使用（见 §7.2）。无 `past` 条目时为 `null`。LLM 抽取时本就理解了"今天""这个周末"，顺带输出，边际成本接近零。

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

**溯源识别号**：写入 `EKEvent.url`，格式为：

```
quickadd://event/<session_uuid>?d=past      // 或 d=future
```

**`direction` 直接编码在 URL 中，不依赖本地数据库反查。** 这样重装 App 或更换设备后，日历里的历史事件依然自带来源信息——对一个档案型应用，这点很重要。

一个字段解决四件事：

1. **幂等** — 重复提交时可靠识别已创建项
2. **来源判定（M2）** — 区分 `plan` / `recap` / `unknown`，三者可执行的动作不同（见 §7.1）
3. **反向跳转** — 从日历点回 QuickAdd 查看原始记录
4. **跨设备存活** — 不依赖 SwiftData 数据完整性

**双写双读**：附注中的 `{session_id}` 作为兜底。读取时先取 `EKEvent.url`，取不到再正则扫 `notes`——应对 Exchange / Google 等日历源不同步 `url` 字段的情况。

---

## 7. 冲突处理（M2）

回记与已有日程冲突的处理。这是本项目复杂度最高的模块，独立于 M0/M1。

### 7.1 三类冲突与来源约束

| 类型 | 场景 | 处理 |
|---|---|---|
| **A. 同一件事的两个副本** | 计划「周三 15:00 和张三开会」，实际开了，回记「周三下午和张三聊了两小时」 | 建议 `merge`：更新原事件时间/附注，不新建 |
| **B. 幽灵计划** | 计划「周三 15:00 健身」，没去；回记「周三下午在家躺着」 | 建议 `markMissed` |
| **C. 时间重叠但不同事** | 计划「15:00 开会」，回记「15:00–16:00 写代码」 | 仅提示，不建议动作 |

判定核心是"是否同一件事"，纯时间比对无法解决（计划 15:00、实际 15:30 开始，时间根本对不上），必须语义判断。

**动作白名单由 origin 决定，在 Swift 侧强制过滤——LLM 越权的建议直接丢弃：**

| origin | 允许的动作 |
|---|---|
| `plan` | `merge` / `markMissed` / `delete` |
| `recap` | **仅 `merge`**（去重）。已有回记记录的是真实发生过的事，不得标记未执行或删除 |
| `unknown` | **仅 `merge`** |

**为什么 `unknown` 只能 merge——错误代价不对称：**

- 把手动回记误判为计划 → 给真实发生过的事打上「未执行」标记 → **污染档案，伤害大**
- 把计划误判为手动回记 → 漏报一条幽灵计划 → **只是少提醒一次，代价小**

因此来源不确定时宁可漏报，绝不误标。

### 7.2 粗筛：按范围，不按条目

**不能逐条按 ±N 小时窗口粗筛。** 幽灵计划的定义就是"日历上有、回记里没提"，逐条粗筛以回记条目为锚点，结构上永远扫不到它。

正确做法以**时间段**为锚点：

```
① 第一次 LLM 调用：抽取，产出 items + recap_range
      ↓
② Swift 粗筛：拉取 recap_range 内全部已有事件，逐条判定 origin
   → 无候选则 conflictStatus = .notApplicable，流程结束
      ↓
③ 第二次 LLM 调用：带候选清单，产出 proposals
      ↓
④ Swift 过滤越权建议（§7.1 白名单）→ UI 呈现 → 用户逐条确认 → 执行
```

**范围兜底**：`recap_range` 缺失或不合理时，取所有 `direction == past` 条目的 `min(start)` → `max(end)`，各外扩 2 小时。与 LLM 给出的范围取并集。

**截断**：范围 > 3 天 或 候选 > 20 条 → 跳过冲突检测，`conflictStatus = .skipped`，UI 明确提示"本次回记跨度较大，已跳过冲突检查"。

理由是**判定准确率**与**UI 可用性**：跨度大时 LLM 判断同一性的准确率下降，且一次让用户审阅 20+ 条建议不现实。**不是 token 成本**——在 1M 上下文与当前价格下成本不构成约束（见 §8.5）。

**不合并为单次调用**：大部分 session 是纯规划，第二次调用根本不触发；且把日历事件塞进第一次调用会在静态段之后插入动态内容，**打掉 DeepSeek 的上下文缓存**（见 §5.1）。两次调用职责清晰，第二次失败可干净降级为"全部新建"。

### 7.3 候选事件的引用方式

传给 LLM 的候选事件编短序号 `#1 #2 #3`，**LLM 引用序号，不引用 `eventIdentifier`**。Swift 侧映射回真实 identifier，序号越界直接丢弃该条建议。

与"日历用名称不用 identifier"（§3.2）同一原则：让 LLM 复述 UUID 是在邀请它幻觉。

不设 `confidence` 字段——LLM 自评置信度不可靠，`reason` 已足够支撑用户判断。

### 7.4 幽灵计划：标记，不删除

**`delete` 必须被强烈抑制，这条写进系统提示词。**

日历在本项目中是档案。「计划了健身但没去」本身就是真实历史，删掉等于篡改。半年后回看，"这周计划三次健身一次没去"是有价值的信息。

- `markMissed` 的实现：**标题加前缀 emoji**（如 `🚫 🏋️ 健身`）。日历月/周视图中一眼可辨，完全可逆（去前缀即可），前缀符号在设置中可改
- `delete` 只保留给"这条计划本身是错的 / 重复的"，**默认不勾选且需二次确认**
- 系统提示词须明确：**不得因"未执行"而建议删除**

### 7.5 降低 `unknown` 占比

**① `creationDate` 启发式——按方向区别对待**

`EKCalendarItem.creationDate` 提示了创建时刻与事件时刻的先后关系。**它不足以判定来源**，但两个推断方向的风险完全不对称，因此处理方式不同：

| 信号 | 处理 | 依据 |
|---|---|---|
| `creationDate > endDate + 2h`（指向 `recap`） | **自动采信**，不再询问用户 | `unknown` 与 `recap` 的动作白名单同为 merge-only，采信**不改变任何行为**，纯粹减少打扰 |
| `creationDate < startDate - 24h`（指向 `plan`） | **仅预选**「这是计划」按钮，须用户点击才生效 | 这是唯一会**解锁 `markMissed` / `delete`** 的方向，不可由启发式决定 |
| 其他 / `creationDate == nil` | 不预选，正常询问 | 信号过弱 |

```
⚠️ 「和老王吃饭」 昨天 19:00 生活 · 来源未知
   （创建于事件结束后 3 小时，看起来是手动补记）
   [ 这是计划 ]  [ 这是我手动记的 ]  [ 忽略 ]
```

**为什么不用它解锁破坏性动作**：即使准确率很高，用户点一次按钮即可给出确定答案。用一个会出错的猜测去省掉一次点击，换来的是偶尔给真实发生过的事打上「未执行」标记——不划算。启发式的职责是让那次点击更省力，不是省掉它。

**指向 `plan` 方向的已知失败模式**：

- `creationDate` 为可选值，部分日历源不提供
- **移动过的事件**：`creationDate` 不随事件时间改变。上月创建的下周计划被拖到上周二后，`creationDate` 仍是上月
- **重复事件**：单次实例的 `startDate` 对应的是整个系列的 `creationDate`
- **日历迁移**：跨账户迁移会让全部事件的 `creationDate` 挤在导入时刻。此后所有过去事件都呈现"创建于事件之后"——这会使幽灵计划检测失效，但只造成降级，不造成误标

**② 一键标注，写入本地 `EventOriginTag` 表**

用户点选后记住，下次同一事件不再询问。

**存本地表，不写回日历事件**：用户手动创建的事件，QuickAdd 不应擅自修改其 `notes` / `url`。代价是不跨设备同步，但 `eventIdentifier` 本身跨设备就不稳定，同步了也未必对得上。

### 7.6 执行期的并发保护

从生成建议到用户点确认之间，事件可能被其他设备修改。执行前比对 `targetSnapshot`（标题 + 时间），不一致则跳过该条并提示"这条日程已被修改，请重新检查"。

**硬底线**：LLM 只产出建议，所有对已有日历数据的修改/删除必须经用户在 UI 上显式确认。任何情况下都不自动删除。

### 7.7 UI 呈现

草稿审阅页分两段，冲突段仅在有建议时出现：

```
【将要添加】
  📊 过 Q3 方案      今天 10:00–11:30   工作
  🦷 牙齿检查        今天 15:00         个人

【与已有日程的冲突】                        [全部忽略]
  ⚠️ 「与张三开会」  今天 15:00–16:00  工作 · 计划
     合并 —— 回记中「和张三聊了两小时」与这条指向同一场会议，
             实际结束时间比计划晚一小时
     [✓ 合并并更新时间]   [新建为独立事件]   [忽略]

  ⚠️ 「健身」        今天 18:00        生活 · 计划
     标记未执行 —— 回记完整覆盖 18:00–21:00 且未提及健身
     [ 标记未执行 ]   [ 删除 ]   [✓ 保持不变]
```

原则：`reason` 必须以人话展示；删除永不是默认选项；提供「全部忽略」一键跳过。

---

## 8. 模型接入

**单一 `OpenAICompatibleProvider`**，不为每个模型写独立实现。配置三项即可切换模型：

```
baseURL  +  apiKey（Keychain）  +  modelId
```

代码内拼接 `/chat/completions`。覆盖 DeepSeek / OpenAI / Moonshot / 硅基流动 / OpenRouter / 本地 Ollama。设置页提供 preset 一键填充。

### 8.1 当前目标：DeepSeek

| 项 | 值 |
|---|---|
| `baseURL` | `https://api.deepseek.com`（**不带 `/v1`**） |
| `modelId` | `deepseek-v4-flash` |
| 合法备选 | `deepseek-v4-pro`（旧 id `deepseek-chat` / `deepseek-reasoner` 已于 2026-07-24 停用） |
| 上下文 / 最大输出 | 1M / 384K tokens |

`deepseek-v4-flash` 恒指向最新版本，不带日期后缀（当前为 DeepSeek-V4-Flash-0731）。

### 8.2 Thinking

**默认开启，`reasoning_effort` 默认 `low`，设置中可调（low / high / max）。**

本项目最大的质量风险是中文日期推理（"下周一"、"周五之前"、"聊了一个半小时"），thinking 正对症。抽取任务不需要深度推理，`low` 足以支撑一步日期算术。M2 的冲突语义判定可单独提高档位。

可用 `thinking: {"type": "disabled"}` 关闭。

> ⚠️ **待实测**：thinking 开启时 JSON 落在 `content` 还是被推理内容污染（旧版 reasoner 将推理置于 `reasoning_content`）。首次调用必须打印完整响应体确认，不可假设。

### 8.3 结构化输出：仅 `json_object`

DeepSeek **不支持 `json_schema`**，`response_format.type` 只接受 `text` / `json_object`。因此走「prompt 内嵌 schema + 健壮解析 + 校验层」路线。

四项已知约束及对策：

| 约束 | 对策 |
|---|---|
| prompt 必须含 "json" 字样并给出样例，否则可能持续输出空白直至耗尽 token | 静态段已内嵌 schema 示例（§5.3），**列入 prompt checklist 保证不被重构丢失** |
| 有概率返回空 `content`（官方已知问题） | 触发自动重试（见 §8.4） |
| `finish_reason == "length"` 时 JSON 被截断 | `max_tokens` 设 8000（thinking 可能占额度）；**显式检查 `finish_reason`**，作为明确失败而非留给解析器报错 |
| 只保证合法 JSON，不保证字段结构 | 由校验层兜底（§5.4） |

### 8.4 分层解析策略

```
① JSONDecoder 直接解码                          → 成功则进校验层
② 失败：剥离 ```json 代码块 / 取首个 { 至末个 }  → 再次解码
③ 仍失败，或 content 为空，或 finish_reason=length
   → 自动重试 API 一次（仅一次）
④ 仍失败 → status = .failed，原文保留，UI 提供手动重试
```

第 ② 层是廉价保险——即便指定 `json_object`，模型偶尔仍会添加包裹。
第 ③ 层**严格限制单次重试**，不做指数退避、不做循环重试，避免网络不佳时长时间阻塞用户。

### 8.5 成本

价格（每 1M tokens）：输入缓存命中 `$0.0028` / 未命中 `$0.14`，输出 `$0.28`。

按每日 10 次、每次输入约 1800 token、输出约 800 token 估算，**全部缓存未命中的最坏情况约 $0.14/月**。

> **成本不构成设计约束。** 不得为节省 token 牺牲质量——该开 thinking 就开，该发第二次调用就发，该多带候选事件就带。
>
> 缓存命中与未命中相差 50 倍，但绝对值均可忽略；§5.1 的静态段顺序约束**其理由是首字延迟，不是成本**。

---

## 9. 权限

| 权限 | API | 请求时机 |
|---|---|---|
| 日历 | `requestFullAccessToEvents()` | 首次进入设置页配置日历映射时 |
| 提醒事项 | `requestFullAccessToReminders()` | 同上 |
| 麦克风 + 语音识别 | M1 | 首次录音时 |

**需要完整读权限**（而非只写），因为要枚举日历列表、并在 M2 读取已有事件做冲突检测。授权文案须说明读取用途。

---

## 10. 界面

**主屏**：中部欢迎语/提示语，底部 Liquid Glass 输入条。M0 只有文本输入 + 发送，但**布局按最终形态预留语音按钮位置**，M1 直接填入。

**草稿审阅**：卡片列表。每张卡片可勾选、编辑（标题/emoji/时间/日历/附注）、删除。`needsConfirmation` 的卡片标黄并显示原因。底部「添加所选 (n)」。

**日志**：session 列表 → 详情（原始输入 / 抽取结果 / 已写入哪些 / 模型与耗时）。

**设置**：模型配置、日历映射与语义说明、提醒列表映射、格式规范。

**导航**：导航栏左上 → 日志，右上 → 设置（sheet）。

> **不采用左滑抽屉侧边栏**：与系统左边缘返回手势冲突，非 HIG 推荐的 iPhone 模式，且仅两个入口不值得。

---

## 11. M0 验收标准

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

## 12. 明确不做

- 读取「语音备忘录」App 的录音 —— **技术上不可行**，其数据位于私有容器，无公开 API 或 entitlement
- 重复事件（RRULE）
- 完整的 tool-calling agent loop —— 追问降级为结构化输出中的 `clarifications` 字段
- 左滑抽屉侧边栏
- iOS 之外的平台
- 跨时区处理 —— 统一使用设备当前时区

---

## 13. 待确认

- [ ] **thinking 开启时的响应结构**：JSON 落在 `content` 还是被推理内容污染。首次调用打印完整响应体确认（见 §8.2）
- [ ] `reasoning_effort` 的实际档位选择——`low` 是否足以支撑中文日期推理，需用 §11 验收用例实测
- [ ] §7.2 的截断阈值（3 天 / 20 条）为估计值，待实测调整
- [ ] §7.5 的 `creationDate` 阈值（+2h / -24h）为估计值，待实测调整

---

## 14. 测试策略

按 `AGENTS.md` 的 **lightweight tool** profile，不建重型测试架子。两处例外必须有单元测试：

1. **JSON 解析与容错**
2. **校验层规则**（§5.4 全表）

理由：纯函数、易测、且是最容易产生静默错误的位置。UI 与 EventKit 写入以手动验证为主。
