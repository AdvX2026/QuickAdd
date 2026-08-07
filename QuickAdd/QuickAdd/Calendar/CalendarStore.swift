import EventKit
import Foundation
import Observation

/// The app's only door to EventKit.
///
/// Access is requested lazily — not at launch — so the permission sheet arrives
/// with a reason the user can see (PRD §9).
@Observable
final class CalendarStore {

    private let store = EKEventStore()

    private(set) var eventAccess: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    private(set) var reminderAccess: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .reminder)

    // MARK: - Access

    /// Full access, not write-only: enumerating calendars for the mapping screen
    /// requires reading, and so will conflict detection (PRD §9).
    @discardableResult
    func requestEventAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToEvents()) ?? false
        eventAccess = EKEventStore.authorizationStatus(for: .event)
        return granted
    }

    @discardableResult
    func requestReminderAccess() async -> Bool {
        let granted = (try? await store.requestFullAccessToReminders()) ?? false
        reminderAccess = EKEventStore.authorizationStatus(for: .reminder)
        return granted
    }

    var hasEventAccess: Bool { eventAccess == .fullAccess }
    var hasReminderAccess: Bool { reminderAccess == .fullAccess }

    // MARK: - Calendars

    /// Subscribed calendars (holidays, sports fixtures) come back from EventKit
    /// but reject writes. Filtering them here keeps them out of the mapping UI,
    /// where picking one would fail silently at commit time (PRD §6.2).
    func writableCalendars() -> [EKCalendar] {
        store.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func writableReminderLists() -> [EKCalendar] {
        store.calendars(for: .reminder)
            .filter(\.allowsContentModifications)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Resolves by identifier, falling back to a title match.
    ///
    /// Identifiers are stable in normal use but an account re-login can
    /// invalidate them; recovering by title spares the user a full
    /// reconfiguration (PRD §6.2).
    ///
    /// The title fallback searches every writable calendar, including ones
    /// settings has disabled, so it can land on a duplicate the user already
    /// ruled out. When a title answers for more than one calendar this fails
    /// instead of picking: writing to the wrong account is silent and, on a
    /// shared work calendar, not private.
    func calendar(identifier: String?, title: String?, for entity: EKEntityType) throws -> EKCalendar {
        let all = entity == .event ? writableCalendars() : writableReminderLists()

        if let identifier, let match = all.first(where: { $0.calendarIdentifier == identifier }) {
            return match
        }

        guard let title else { throw CalendarStoreError.calendarUnavailable("") }

        let matches = all.filter { $0.title == title }
        switch matches.count {
        case 1:  return matches[0]
        case 0:  throw CalendarStoreError.calendarUnavailable(title)
        default: throw CalendarStoreError.calendarAmbiguous(title)
        }
    }

    // MARK: - Committing

    struct CommitReport {
        var written: [DraftItem] = []
        var failures: [(item: DraftItem, message: String)] = []
        var skipped: Int = 0
    }

    /// Writes the selected drafts.
    ///
    /// Items carrying a `committedIdentifier` are skipped rather than written
    /// again: tapping "add" twice on the same session must not double-book the
    /// user's calendar.
    func commit(
        items: [DraftItem],
        sessionID: UUID,
        formatter: EventFormatter
    ) -> CommitReport {
        var report = CommitReport()

        for item in items {
            guard item.isSelected else { continue }
            guard item.committedIdentifier == nil else {
                report.skipped += 1
                continue
            }

            do {
                let identifier = try write(item, sessionID: sessionID, formatter: formatter)
                item.committedIdentifier = identifier
                report.written.append(item)
            } catch {
                report.failures.append((item, error.localizedDescription))
            }
        }
        return report
    }

    private func write(
        _ item: DraftItem,
        sessionID: UUID,
        formatter: EventFormatter
    ) throws -> String {
        switch item.kind {
        case .event:   try writeEvent(item, sessionID: sessionID, formatter: formatter)
        case .reminder: try writeReminder(item, sessionID: sessionID, formatter: formatter)
        }
    }

    private func writeEvent(
        _ item: DraftItem,
        sessionID: UUID,
        formatter: EventFormatter
    ) throws -> String {
        guard let start = item.startDate else {
            throw CalendarStoreError.missingStartDate
        }
        let calendar = try calendar(identifier: item.resolvedCalendarID,
                                    title: item.calendarName,
                                    for: .event)

        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = formatter.title(for: item)
        event.notes = formatter.notes(for: item, sessionID: sessionID)
        event.url = formatter.url(for: item, sessionID: sessionID)
        event.startDate = start
        event.endDate = item.endDate ?? start.addingTimeInterval(3600)
        event.isAllDay = item.isAllDay

        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier
    }

    private func writeReminder(
        _ item: DraftItem,
        sessionID: UUID,
        formatter: EventFormatter
    ) throws -> String {
        let calendar = try calendar(identifier: item.resolvedCalendarID,
                                    title: item.calendarName,
                                    for: .reminder)

        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = formatter.title(for: item)
        reminder.notes = formatter.notes(for: item, sessionID: sessionID)
        reminder.url = formatter.url(for: item, sessionID: sessionID)

        if let due = item.dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: due)
        }
        // Back-logged reminders describe something already done.
        if item.direction == .past {
            reminder.isCompleted = true
            reminder.completionDate = item.dueDate ?? Date()
        }

        try store.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }
}

enum CalendarStoreError: LocalizedError {
    case missingStartDate
    case calendarUnavailable(String)
    case calendarAmbiguous(String)

    var errorDescription: String? {
        switch self {
        case .missingStartDate:
            "事件缺少开始时间"
        case .calendarUnavailable(let name):
            "找不到日历「\(name)」，可能已被删除或重命名"
        case .calendarAmbiguous(let name):
            "有多个账户都存在名为「\(name)」的日历，请到设置里只启用其中一个"
        }
    }
}
