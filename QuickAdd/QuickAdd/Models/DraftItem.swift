import Foundation
import SwiftData

/// A single proposed calendar event or reminder, after validation and before
/// the user has approved it.
@Model
final class DraftItem {
    var id: UUID = UUID()
    var kind: Kind = Kind.event

    var title: String = ""
    var emoji: String?
    var details: String = ""

    /// Calendar name as the model produced it. Kept even when it fails to
    /// resolve, so the review UI can show what was attempted.
    var calendarName: String = ""
    /// `EKCalendar.calendarIdentifier`; nil means the name did not resolve.
    var resolvedCalendarID: String?

    var startDate: Date?
    var endDate: Date?
    var dueDate: Date?
    var isAllDay: Bool = false

    var direction: Direction = Direction.future

    /// Model self-reported that it inferred the time from a vague phrase
    /// ("晚上", "下午") rather than reading it off the input.
    var timeVague: Bool = false

    /// Set by the validator. Never blocks; only surfaces a yellow card.
    var needsConfirmation: Bool = false
    var confirmReason: String?

    var isSelected: Bool = true

    /// `EKEvent`/`EKReminder` identifier once written. Also the idempotency key
    /// for re-submitting the same session.
    var committedIdentifier: String?

    var session: CaptureSession?

    init(
        kind: Kind,
        title: String,
        emoji: String? = nil,
        details: String = "",
        calendarName: String,
        resolvedCalendarID: String? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        dueDate: Date? = nil,
        isAllDay: Bool = false,
        direction: Direction,
        timeVague: Bool = false
    ) {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.emoji = emoji
        self.details = details
        self.calendarName = calendarName
        self.resolvedCalendarID = resolvedCalendarID
        self.startDate = startDate
        self.endDate = endDate
        self.dueDate = dueDate
        self.isAllDay = isAllDay
        self.direction = direction
        self.timeVague = timeVague
    }

    enum Kind: String, Codable {
        case event
        case reminder
    }

    /// Which way in time the item points. Drives validation and, later, conflict
    /// detection — never which calendar the item lands in.
    enum Direction: String, Codable {
        /// Back-logging something already done.
        case past
        /// Planning something ahead.
        case future
    }
}

extension DraftItem {
    /// Flags the card without failing it. First reason wins so the user sees the
    /// most specific problem rather than the last one checked.
    func flag(_ reason: String) {
        guard !needsConfirmation else { return }
        needsConfirmation = true
        confirmReason = reason
    }
}
