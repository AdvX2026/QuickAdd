import SwiftData
import SwiftUI

/// The draft cards, before anything touches the real calendar.
///
/// Nothing here is written until the user taps add, and flagged cards are shown
/// but never blocked — the validator's job was to surface problems, not to
/// decide on the user's behalf (PRD §5.4).
struct ReviewView: View {

    @Environment(\.modelContext) private var context

    @Bindable var session: CaptureSession
    let coordinator: CaptureCoordinator

    @State private var editing: DraftItem?

    private var selectedCount: Int {
        session.items.count { $0.isSelected }
    }

    private var events: [DraftItem] { session.items.filter { $0.kind == .event } }
    private var reminders: [DraftItem] { session.items.filter { $0.kind == .reminder } }

    var body: some View {
        VStack(spacing: 0) {
            List {
                if !events.isEmpty {
                    Section("日程") {
                        ForEach(events) { item in
                            DraftCard(item: item) { editing = item }
                        }
                        .onDelete { remove(events, at: $0) }
                    }
                }
                if !reminders.isEmpty {
                    Section("提醒事项") {
                        ForEach(reminders) { item in
                            DraftCard(item: item) { editing = item }
                        }
                        .onDelete { remove(reminders, at: $0) }
                    }
                }
                if session.items.isEmpty {
                    ContentUnavailableView(
                        "没有识别出日程",
                        systemImage: "tray",
                        description: Text("这段话里没有可以整理成日程或提醒的内容。")
                    )
                }
            }
            .listStyle(.insetGrouped)

            footer
        }
        .sheet(item: $editing) { item in
            DraftEditor(item: item)
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let message = coordinator.lastCommitMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("放弃") { coordinator.discard(session) }
                    .buttonStyle(.glass)

                Button {
                    Task {
                        await coordinator.commitSelected(in: session)
                        if session.status == .committed { coordinator.finish() }
                    }
                } label: {
                    Text(selectedCount > 0 ? "添加所选 (\(selectedCount))" : "添加")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(selectedCount == 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        // Clears the input bar that sits underneath.
        .padding(.bottom, 80)
    }

    /// Deletes through the context, not just out of the relationship array.
    /// Dropping the reference alone would leave the row behind as an orphan the
    /// cascade rule can no longer reach.
    private func remove(_ source: [DraftItem], at offsets: IndexSet) {
        for index in offsets {
            let target = source[index]
            session.items.removeAll { $0.id == target.id }
            context.delete(target)
        }
    }
}

// MARK: - Card

private struct DraftCard: View {

    @Bindable var item: DraftItem
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                item.isSelected.toggle()
            } label: {
                Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isSelected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.isSelected ? "取消选择" : "选择")

            VStack(alignment: .leading, spacing: 4) {
                Text("\(item.emoji.map { $0 + " " } ?? "")\(item.title)")
                    .font(.body.weight(.medium))

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if item.needsConfirmation, let reason = item.confirmReason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onTapGesture(perform: onEdit)
    }

    private var subtitle: String {
        var parts: [String] = []

        switch item.kind {
        case .event:
            if let start = item.startDate {
                parts.append(Self.range(start, item.endDate, allDay: item.isAllDay))
            } else {
                parts.append("未设置时间")
            }
        case .reminder:
            parts.append(item.dueDate.map { "截止 " + Self.moment($0) } ?? "无截止时间")
        }

        parts.append(item.calendarName)
        parts.append(item.direction == .past ? "回记" : "规划")
        return parts.joined(separator: " · ")
    }

    private static func range(_ start: Date, _ end: Date?, allDay: Bool) -> String {
        if allDay { return dayOnly(start) + " 全天" }
        guard let end else { return moment(start) }
        let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
        return sameDay
            ? "\(moment(start)) – \(timeOnly(end))"
            : "\(moment(start)) – \(moment(end))"
    }

    private static func moment(_ date: Date) -> String { format(date, "MM月dd日(E) HH:mm") }
    private static func dayOnly(_ date: Date) -> String { format(date, "MM月dd日(E)") }
    private static func timeOnly(_ date: Date) -> String { format(date, "HH:mm") }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
