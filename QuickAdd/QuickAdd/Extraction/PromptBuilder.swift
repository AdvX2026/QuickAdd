import Foundation

/// Assembles the two prompt segments (PRD §5.1).
///
/// They are separate messages on purpose: DeepSeek's context cache matches on
/// message boundaries, so folding the timestamp into the same message as the
/// rules made every call a cache miss. Measured 0/856 concatenated versus
/// 896/1018 split.
///
/// The wording here is not a first draft — every rule in the time section was
/// added to fix a defect the spike reproduced. Changing them casually will
/// reintroduce the jitter they removed.
struct PromptBuilder {

    let settings: AppSettings

    /// Byte-identical between calls as long as settings do not change.
    func staticSegment() -> String {
        """
        你是一个日程抽取器。你唯一的职责，是把用户的自然语言叙述转成日历事件与提醒事项的结构化 json 数据。

        你不是生活助手。不要闲聊，不要给建议，不要评价用户的安排，不要补充用户没有说过的内容。

        ## 一、分类：事件还是提醒

        - 有明确的时间点或时间段，或叙述的是已经发生的事 → 事件 events
        - 只有截止日期、或完全没有时间信息的待办 → 提醒 reminders

        ## 二、时间方向 direction

        - past：用户在叙述已经做过的事（回记）
        - future：用户在叙述打算做的事（规划）

        ## 三、时间推算规则

        - 「X 之前」「X 前」这类截止表述：X 当天算在期限内，截止时间一律取 X 当天的 23:59。不要提前到 X 的前一天，也不要延后到 X 之后
        - 用户没有说明时长的事件：默认时长 1 小时
        - 用户只给了模糊时段（例如「晚上」「下午」）：仍要给出具体时间，并把该条的 timeVague 设为 true
        - 时间明确的条目，timeVague 设为 false

        ## 四、归类 calendar

        \(calendarSection())

        ## 五、输出格式

        必须输出合法的 json。不要输出 json 以外的任何文字，不要用 markdown 代码块包裹。

        json 结构如下：

        \(schemaExample())

        字段说明：

        - title：简洁的标题，不要包含 emoji
        - emoji：一个与该条内容相关的 emoji
        - details：更详细的描述；没有则填空字符串
        - calendar：上述列表中的名称之一
        - start / end：ISO8601 格式，必须带时区偏移
        - allDay：是否为全天事件
        - due：提醒的截止时间，ISO8601 带时区偏移；没有截止时间则为 null
        - direction："past" 或 "future"
        - timeVague：时间是你根据模糊表述推测的则为 true，用户明确说了时间则为 false
        - recap_range：用户这段叙述所谈论的时间范围。取决于叙述本身覆盖的时段，而不是抽取出的条目的时间跨度——例如用户在讲「今天」做了什么，范围就是今天整天。没有 past 条目时为 null

        ## 六、禁止

        - 禁止输出相对时间词（例如「明天」「下周」），一律换算为 ISO8601 绝对时间
        - 禁止输出重复规则
        - 禁止编造用户没有提到的细节
        - 没有可抽取的内容时，events 与 reminders 返回空数组，不要硬凑
        """
    }

    /// Changes every call; kept out of the static segment so the cache can hit.
    func dynamicSegment(now: Date = Date(), timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2

        let ymd = DateFormatter()
        ymd.locale = Locale(identifier: "en_US_POSIX")
        ymd.timeZone = timeZone
        ymd.dateFormat = "yyyy-MM-dd"

        let weekdayNames = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        let weekday = weekdayNames[calendar.component(.weekday, from: now) - 1]
        let monday = calendar.date(from: calendar.dateComponents(
            [.yearForWeekOfYear, .weekOfYear], from: now)) ?? now

        return """
        当前时间：\(ISO8601.string(from: now, timeZone: timeZone))
        时区：\(timeZone.identifier)
        今天是：\(weekday)
        本周一：\(ymd.string(from: monday))
        """
    }

    // MARK: - Sections

    /// Events and reminders draw from different sets, so the model is told both
    /// explicitly rather than left to guess that one list covers both.
    private func calendarSection() -> String {
        var parts: [String] = []

        let events = settings.usableCalendars
        if events.isEmpty {
            parts.append("事件（events）的 calendar 统一填 \"默认\"。")
        } else {
            parts.append("""
            事件（events）的 calendar 必须从下列名称中选择一个，不得自创：

            \(list(events))

            实在无法判断时使用「\(settings.defaultCalendarName)」。
            """)
        }

        let reminders = settings.usableReminderLists
        if reminders.isEmpty {
            parts.append("提醒（reminders）的 calendar 统一填 \"默认\"。")
        } else {
            parts.append("""
            提醒（reminders）的 calendar 必须从下列名称中选择一个，不得自创：

            \(list(reminders))

            实在无法判断时使用「\(settings.defaultReminderListName)」。
            """)
        }

        return parts.joined(separator: "\n\n")
    }

    private func list(_ configs: [CalendarConfig]) -> String {
        configs.map { config in
            let definition = config.definition.trimmingCharacters(in: .whitespacesAndNewlines)
            return definition.isEmpty ? "- \(config.title)" : "- \(config.title)：\(definition)"
        }
        .joined(separator: "\n")
    }

    /// A concrete example is mandatory, not decorative: without the word "json"
    /// and a sample, `json_object` mode can emit blank output until it exhausts
    /// the token budget (PRD §8.3).
    private func schemaExample() -> String {
        """
        {
          "events": [
            {
              "title": "过 Q3 方案",
              "emoji": "📊",
              "details": "与张三讨论 Q3 方案细节",
              "calendar": "\(settings.usableCalendars.first?.title ?? "默认")",
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
              "calendar": "\(settings.usableReminderLists.first?.title ?? "默认")",
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
        """
    }
}
