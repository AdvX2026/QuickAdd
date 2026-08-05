import Foundation

/// Turns a decoded extraction response into draft cards (PRD §5.4).
///
/// The governing rule: **validation never fails a capture.** A problem the user
/// can see and fix in one tap becomes a yellow card, not an error. Only items
/// that could not represent anything at all are dropped.
enum ExtractionValidator {

    struct Context {
        /// Calendar display name → `EKCalendar.calendarIdentifier`.
        var calendarsByName: [String: String]
        /// Fallback when the model names a calendar that does not exist.
        var defaultCalendarName: String
        var now: Date

        init(calendarsByName: [String: String], defaultCalendarName: String, now: Date = Date()) {
            self.calendarsByName = calendarsByName
            self.defaultCalendarName = defaultCalendarName
            self.now = now
        }
    }

    struct Result {
        var items: [DraftItem] = []
        /// Items discarded outright, with why. Surfaced in the log so a silent
        /// drop is never invisible.
        var dropped: [String] = []
    }

    /// How far from now an item may sit before it is treated as suspicious.
    static let plausibleWindow: TimeInterval = 365 * 24 * 60 * 60

    /// Applied when the model gives an event a start but no end. Mirrors the
    /// prompt's "default to 1 hour" rule; repeated here because prompt rules are
    /// advisory and this one has to hold.
    static let defaultEventDuration: TimeInterval = 60 * 60

    static func validate(_ response: ExtractionResponse, context: Context) -> Result {
        var result = Result()

        for raw in response.events {
            switch makeEvent(raw, context: context) {
            case .success(let item): result.items.append(item)
            case .dropped(let why): result.dropped.append(why)
            }
        }
        for raw in response.reminders {
            switch makeReminder(raw, context: context) {
            case .success(let item): result.items.append(item)
            case .dropped(let why): result.dropped.append(why)
            }
        }
        return result
    }

    private enum Outcome {
        case success(DraftItem)
        case dropped(String)
    }

    // MARK: - Events

    private static func makeEvent(_ raw: ExtractionResponse.RawItem, context: Context) -> Outcome {
        guard let title = cleanTitle(raw.title) else {
            return .dropped("事件缺少标题")
        }

        let resolved = resolveCalendar(raw.calendar, context: context)
        let start = ISO8601.parse(raw.start)
        var end = ISO8601.parse(raw.end)

        // An event with no start cannot be written. Keep it so the user can fix
        // the time in the card editor, but leave it unselected so committing
        // the batch cannot silently skip it.
        if let start, end == nil {
            end = start.addingTimeInterval(defaultEventDuration)
        }

        let item = DraftItem(
            kind: .event,
            title: title,
            emoji: cleanEmoji(raw.emoji),
            details: raw.details ?? "",
            calendarName: resolved.name,
            resolvedCalendarID: resolved.id,
            startDate: start,
            endDate: end,
            isAllDay: raw.allDay ?? false,
            direction: parseDirection(raw.direction, reference: start, now: context.now),
            timeVague: raw.timeVague ?? false
        )

        if start == nil {
            item.isSelected = false
            item.flag("缺少时间，补充后才能添加")
        }

        // end < start is the model contradicting itself. Repair rather than
        // drop; the corrected duration is usually right and always visible.
        if let s = start, let e = end, e < s {
            item.endDate = s.addingTimeInterval(defaultEventDuration)
            item.flag("结束时间早于开始时间，已修正为 1 小时")
        }

        applyCommonFlags(to: item, resolved: resolved, raw: raw, reference: start, context: context)
        return .success(item)
    }

    // MARK: - Reminders

    private static func makeReminder(_ raw: ExtractionResponse.RawItem, context: Context) -> Outcome {
        guard let title = cleanTitle(raw.title) else {
            return .dropped("提醒缺少标题")
        }

        let resolved = resolveCalendar(raw.calendar, context: context)
        // A reminder with no due date is legitimate — plenty of todos have no
        // deadline — so unlike events this is not flagged.
        let due = ISO8601.parse(raw.due)

        let item = DraftItem(
            kind: .reminder,
            title: title,
            emoji: cleanEmoji(raw.emoji),
            details: raw.details ?? "",
            calendarName: resolved.name,
            resolvedCalendarID: resolved.id,
            dueDate: due,
            direction: parseDirection(raw.direction, reference: due, now: context.now),
            timeVague: raw.timeVague ?? false
        )

        applyCommonFlags(to: item, resolved: resolved, raw: raw, reference: due, context: context)
        return .success(item)
    }

    // MARK: - Shared checks

    private static func applyCommonFlags(
        to item: DraftItem,
        resolved: ResolvedCalendar,
        raw: ExtractionResponse.RawItem,
        reference: Date?,
        context: Context
    ) {
        if !resolved.matched {
            item.flag("日历「\(raw.calendar ?? "未指定")」不存在，已归入\(resolved.name)")
        }

        if let date = reference {
            if abs(date.timeIntervalSince(context.now)) > plausibleWindow {
                item.flag("时间距今超过一年")
            } else if item.direction == .past, date > context.now {
                item.flag("标记为回记但时间在未来")
            } else if item.direction == .future, date < context.now {
                item.flag("标记为规划但时间已过去")
            }
        }

        if item.timeVague {
            item.flag("时间为推测")
        }
    }

    // MARK: - Field normalisation

    private static func cleanTitle(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            return nil
        }
        return t
    }

    /// The prompt asks for the emoji in its own field, but models sometimes send
    /// a whole word or an empty string instead. Accept only a single glyph.
    private static func cleanEmoji(_ raw: String?) -> String? {
        guard let e = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !e.isEmpty else {
            return nil
        }
        guard e.count == 1, e.unicodeScalars.contains(where: { $0.properties.isEmoji }) else {
            return nil
        }
        return e
    }

    private struct ResolvedCalendar {
        var name: String
        var id: String?
        var matched: Bool
    }

    private static func resolveCalendar(
        _ raw: String?,
        context: Context
    ) -> ResolvedCalendar {
        let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty, let id = context.calendarsByName[name] {
            return ResolvedCalendar(name: name, id: id, matched: true)
        }
        return ResolvedCalendar(
            name: context.defaultCalendarName,
            id: context.calendarsByName[context.defaultCalendarName],
            matched: false
        )
    }

    /// Recovers a usable direction when the model omits it or sends something
    /// unexpected, by comparing the item's own time against now.
    private static func parseDirection(
        _ raw: String?,
        reference: Date?,
        now: Date
    ) -> DraftItem.Direction {
        if let raw, let parsed = DraftItem.Direction(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        guard let reference else { return .future }
        return reference < now ? .past : .future
    }
}
