#!/usr/bin/env swift
//
// deepseek-probe — M0 provider spike.
//
// Answers two questions before any app code gets written:
//   1. What does the response body actually look like with thinking on?
//      (Is the JSON in `content`, or is it polluted by reasoning output?)
//   2. Is deepseek-v4-flash accurate enough at Chinese date reasoning?
//
// Usage:  see Spike/README.md
//

import Foundation

// MARK: - Config

let modelID = "deepseek-v4-flash"
let baseURL = "https://api.deepseek.com"
let maxTokens = 8000

struct Options {
    var effort = "low"          // low | high | max
    var thinking = true
    var input: String?          // nil = use the §11 acceptance case
}

func parseArgs() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = it.next() {
        switch arg {
        case "--effort":       if let v = it.next() { o.effort = v }
        case "--no-thinking":  o.thinking = false
        case "--input":        if let v = it.next() { o.input = v }
        case "-h", "--help":
            print("""
            deepseek-probe [--effort low|high|max] [--no-thinking] [--input "<text>"]
            """)
            exit(0)
        default:
            FileHandle.standardError.write("unknown argument: \(arg)\n".data(using: .utf8)!)
            exit(2)
        }
    }
    return o
}

// MARK: - Secret loading
//
// Never printed, never logged, never written to Spike/out.

func loadAPIKey() -> String {
    if let k = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"],
       !k.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return k.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("secrets/deepseek.key")
    if let s = try? String(contentsOf: path, encoding: .utf8) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
    }
    FileHandle.standardError.write("""
        No API key found.

        Provide it one of two ways (neither reaches git or shell history):

          1. echo 'sk-...' > secrets/deepseek.key      # secrets/ is gitignored
          2. export DEEPSEEK_API_KEY=sk-...

        """.data(using: .utf8)!)
    exit(1)
}

// MARK: - Time context

let tz = TimeZone.current
var cal = Calendar(identifier: .gregorian)
cal.timeZone = tz
cal.firstWeekday = 2 // Monday

let now = Date()

let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.timeZone = tz
    f.formatOptions = [.withInternetDateTime]
    return f
}()

let ymd: DateFormatter = {
    let f = DateFormatter()
    f.timeZone = tz
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

let weekdayNames = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
let todayWeekday = weekdayNames[cal.component(.weekday, from: now) - 1]
let thisMonday = cal.date(from: cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!

// MARK: - Prompt
//
// Chinese, because the input is Chinese and DeepSeek handles the pairing
// better that way. Order follows PRD §5.1: static block first so the
// context cache can hit, dynamic block after.

let staticPrompt = """
你是一个日程抽取器。你唯一的职责，是把用户的自然语言叙述转成日历事件与提醒事项的结构化 json 数据。

你不是生活助手。不要闲聊，不要给建议，不要评价用户的安排，不要补充用户没有说过的内容。

## 一、分类：事件还是提醒

- 有明确的时间点或时间段，或叙述的是已经发生的事 → 事件 events
- 只有截止日期、或完全没有时间信息的待办 → 提醒 reminders

## 二、时间方向 direction

- past：用户在叙述已经做过的事（回记）
- future：用户在叙述打算做的事（规划）

## 二之二、时间推算规则

- 「X 之前」「X 前」这类截止表述：截止时间取 X 当天的 23:59，不得晚于 X 当天
- 用户没有说明时长的事件：默认时长 1 小时
- 用户只给了模糊时段（例如「晚上」「下午」）：仍要给出具体时间，并把该条的 timeVague 设为 true
- 时间明确的条目，timeVague 设为 false

## 三、日历分类 calendar

必须从下列名称中选择一个，不得自创：

- 创意：写作、设计、副业项目、灵感记录。不包括工作范围内的创意任务（那属于 工作）
- 工作：本职工作的会议、任务、汇报、出差。不包括工作场合的私人社交（那属于 生活）
- 生活：日常起居、社交、聚会、家务、购物、出行安排。不包括个人健康与理财（那属于 个人）
- 个人：健康就医、健身、理财、证件办理、个人成长与学习。不包括和朋友一起的活动（那属于 生活）

实在无法判断时使用「生活」。

## 四、输出格式

必须输出合法的 json。不要输出 json 以外的任何文字，不要用 markdown 代码块包裹。

json 结构如下：

{
  "events": [
    {
      "title": "过 Q3 方案",
      "emoji": "📊",
      "details": "与张三讨论 Q3 方案细节",
      "calendar": "工作",
      "start": "2026-08-05T10:00:00+08:00",
      "end": "2026-08-05T11:30:00+08:00",
      "allDay": false,
      "direction": "past",
      "timeVague": false
    }
  ],
  "reminders": [
    {
      "title": "交周报",
      "emoji": "📝",
      "details": "",
      "calendar": "工作",
      "due": "2026-08-06T18:00:00+08:00",
      "direction": "future",
      "timeVague": false
    }
  ],
  "recap_range": {
    "start": "2026-08-05T00:00:00+08:00",
    "end": "2026-08-05T23:59:59+08:00"
  }
}

字段说明：

- title：简洁的标题，不要包含 emoji
- emoji：一个与该条内容相关的 emoji
- details：更详细的描述；没有则填空字符串
- calendar：上述四个日历名称之一
- start / end：ISO8601 格式，必须带时区偏移
- allDay：是否为全天事件
- due：提醒的截止时间，ISO8601 带时区偏移；没有截止时间则为 null
- direction："past" 或 "future"
- timeVague：时间是你根据模糊表述推测的则为 true，用户明确说了时间则为 false
- recap_range：用户这段叙述所谈论的时间范围。取决于叙述本身覆盖的时段，而不是抽取出的条目的时间跨度——例如用户在讲「今天」做了什么，范围就是今天整天。没有 past 条目时为 null

## 五、禁止

- 禁止输出相对时间词（例如「明天」「下周」），一律换算为 ISO8601 绝对时间
- 禁止输出重复规则
- 禁止编造用户没有提到的细节
- 没有可抽取的内容时，events 与 reminders 返回空数组，不要硬凑
"""

let dynamicPrompt = """
当前时间：\(iso.string(from: now))
时区：\(tz.identifier)
今天是：\(todayWeekday)
本周一：\(ymd.string(from: thisMonday))
"""

// PRD §11 acceptance case.
let acceptanceInput = """
今天上午十点跟张三过了下 Q3 方案，聊了一个半小时。下午三点做了牙齿检查。\
明天要交周报，周五之前把机票订了。下周一早上九点有个部门例会。\
晚上想写写那个短篇小说的开头。
"""

// MARK: - Request

let opts = parseArgs()
let userInput = opts.input ?? acceptanceInput
let apiKey = loadAPIKey()

var body: [String: Any] = [
    "model": modelID,
    // Static block is its own message so it is byte-identical across calls,
    // giving the context cache a chance to match on it.
    "messages": [
        ["role": "system", "content": staticPrompt],
        ["role": "system", "content": dynamicPrompt],
        ["role": "user", "content": userInput],
    ],
    "response_format": ["type": "json_object"],
    "max_tokens": maxTokens,
    "reasoning_effort": opts.effort,
]
if !opts.thinking {
    body["thinking"] = ["type": "disabled"]
}

var req = URLRequest(url: URL(string: baseURL + "/chat/completions")!)
req.httpMethod = "POST"
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
req.httpBody = try JSONSerialization.data(withJSONObject: body)
req.timeoutInterval = 180

print("""
─── request ──────────────────────────────────────────────
model            \(modelID)
reasoning_effort \(opts.effort)
thinking         \(opts.thinking ? "enabled (default)" : "disabled")
response_format  json_object
now              \(iso.string(from: now))  \(todayWeekday)
input            \(userInput.prefix(40))…
──────────────────────────────────────────────────────────
""")

let started = Date()
let (data, response) = try await URLSession.shared.data(for: req)
let elapsed = Date().timeIntervalSince(started)

let status = (response as? HTTPURLResponse)?.statusCode ?? -1

// MARK: - Persist raw body
//
// The whole point of the spike: inspect the real response shape.

let outDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Spike/out")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let stamp: String = {
    let f = DateFormatter()
    f.dateFormat = "yyyyMMdd-HHmmss"
    return f.string(from: now)
}()
let rawPath = outDir.appendingPathComponent("raw-\(stamp)-\(opts.effort).json")
try data.write(to: rawPath)

print("\nHTTP \(status)   \(String(format: "%.1f", elapsed))s   raw → \(rawPath.lastPathComponent)")

guard status == 200 else {
    print("\n─── error body ───────────────────────────────────────────")
    print(String(data: data, encoding: .utf8) ?? "<undecodable>")
    exit(1)
}

// MARK: - Response shape
//
// Question 1: which fields actually come back on the message object?

let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
let choice = (root["choices"] as? [[String: Any]])?.first ?? [:]
let message = choice["message"] as? [String: Any] ?? [:]
let finishReason = choice["finish_reason"] as? String ?? "?"

print("""

─── response shape ───────────────────────────────────────
message keys     \(message.keys.sorted().joined(separator: ", "))
finish_reason    \(finishReason)
""")

for key in message.keys.sorted() where key != "content" && key != "role" {
    let v = message[key]
    let desc: String
    if let s = v as? String {
        desc = "String, \(s.count) chars — \(s.prefix(60).replacingOccurrences(of: "\n", with: " "))…"
    } else {
        desc = String(describing: type(of: v))
    }
    print("  \(key.padding(toLength: 16, withPad: " ", startingAt: 0)) \(desc)")
}

if let usage = root["usage"] as? [String: Any] {
    let pairs = usage.keys.sorted().map { "\($0)=\(usage[$0] ?? "?")" }
    print("usage            \(pairs.joined(separator: "  "))")
}
print("──────────────────────────────────────────────────────────")

if finishReason == "length" {
    print("\n⚠️  finish_reason == length — output was truncated, raise max_tokens.")
}

// MARK: - Parse content
//
// Question 2: is the JSON clean, and are the dates right?

let content = message["content"] as? String ?? ""
if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    print("\n⚠️  content is EMPTY — this is the known DeepSeek json_object failure mode.")
    print("    Retry once; if it recurs, the retry policy in PRD §8.4 is load-bearing.")
    exit(1)
}

/// Tier 2 of PRD §8.4: strip fences / take outermost braces.
func salvageJSON(_ s: String) -> String {
    var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("```") {
        t = t.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
    }
    if let first = t.firstIndex(of: "{"), let last = t.lastIndex(of: "}") {
        t = String(t[first...last])
    }
    return t
}

var neededSalvage = false
var parsed: [String: Any]
if let d = content.data(using: .utf8),
   let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
    parsed = o
} else {
    neededSalvage = true
    guard let d = salvageJSON(content).data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
        print("\n⚠️  content is not parseable JSON even after salvage:\n")
        print(content)
        exit(1)
    }
    parsed = o
}

print("""

─── parse ────────────────────────────────────────────────
tier 1 (direct)  \(neededSalvage ? "FAILED" : "ok")
tier 2 (salvage) \(neededSalvage ? "ok — model wrapped or padded the JSON" : "not needed")
──────────────────────────────────────────────────────────
""")

// MARK: - Render results

func fmt(_ raw: Any?) -> String {
    guard let s = raw as? String, !s.isEmpty else { return "—" }
    guard let d = iso.date(from: s) else { return "⚠️ \(s)" }
    let f = DateFormatter()
    f.timeZone = tz
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "MM-dd(E) HH:mm"
    return f.string(from: d)
}

let events = parsed["events"] as? [[String: Any]] ?? []
let reminders = parsed["reminders"] as? [[String: Any]] ?? []

print("\n─── events (\(events.count)) ─────────────────────────────────────")
for e in events {
    let dir = (e["direction"] as? String ?? "?") == "past" ? "回记" : "规划"
    let vague = (e["timeVague"] as? Bool ?? false) ? "  ⚠️时间为推测" : ""
    print("""
      \(e["emoji"] as? String ?? "  ") \(e["title"] as? String ?? "?")
         \(fmt(e["start"])) → \(fmt(e["end"]))   [\(e["calendar"] as? String ?? "?")] \(dir)\(vague)
    """)
}

print("\n─── reminders (\(reminders.count)) ──────────────────────────────")
for r in reminders {
    let dir = (r["direction"] as? String ?? "?") == "past" ? "回记" : "规划"
    let vague = (r["timeVague"] as? Bool ?? false) ? "  ⚠️时间为推测" : ""
    print("""
      \(r["emoji"] as? String ?? "  ") \(r["title"] as? String ?? "?")
         截止 \(fmt(r["due"]))   [\(r["calendar"] as? String ?? "?")] \(dir)\(vague)
    """)
}

if let rr = parsed["recap_range"] as? [String: Any] {
    print("\nrecap_range      \(fmt(rr["start"])) → \(fmt(rr["end"]))")
} else {
    print("\nrecap_range      null")
}

// MARK: - Acceptance check
//
// Only meaningful for the built-in case; skipped for --input.

guard opts.input == nil else { exit(0) }

let today = ymd.string(from: now)
let nextMonday = ymd.string(from: cal.date(byAdding: .day, value: 7, to: thisMonday)!)
let tomorrow = ymd.string(from: cal.date(byAdding: .day, value: 1, to: now)!)

print("""

─── expected (PRD §11) ───────────────────────────────────
  events 4 · reminders 2

  event   past    \(today) 10:00–11:30   工作   过 Q3 方案
  event   past    \(today) 15:00         个人   牙齿检查
  event   future  \(today) 晚上           创意   写短篇小说
  event   future  \(nextMonday) 09:00     工作   部门例会
  remind  future  \(tomorrow)             工作   交周报
  remind  future  本周五之前               生活/个人  订机票  ← 边界项

  边界项「订机票」归到哪个日历，应由日历定义决定；漂移不定说明定义要调。
──────────────────────────────────────────────────────────

counts           events \(events.count)/4   reminders \(reminders.count)/2 \
\(events.count == 4 && reminders.count == 2 ? "✓" : "  ← mismatch")
""")
