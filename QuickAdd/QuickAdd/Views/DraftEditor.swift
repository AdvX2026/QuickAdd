import SwiftUI

/// Fixing a card by hand.
///
/// Most "wrong" extractions are one field off — a time the model guessed, a
/// calendar it picked badly — and correcting that here is faster than another
/// round trip to the model.
struct DraftEditor: View {

    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @Bindable var item: DraftItem

    private var availableCalendars: [CalendarConfig] {
        item.kind == .event ? settings.usableCalendars : settings.usableReminderLists
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("标题", text: $item.title)
                    TextField("Emoji", text: emojiBinding)
                    TextField("备注", text: $item.details, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section("归类") {
                    Picker("日历", selection: $item.calendarName) {
                        ForEach(availableCalendars) { config in
                            Text(config.title).tag(config.title)
                        }
                    }
                    Picker("方向", selection: $item.direction) {
                        Text("回记").tag(DraftItem.Direction.past)
                        Text("规划").tag(DraftItem.Direction.future)
                    }
                    .pickerStyle(.segmented)
                }

                switch item.kind {
                case .event:   eventTimeSection
                case .reminder: reminderTimeSection
                }

                if item.needsConfirmation, let reason = item.confirmReason {
                    Section {
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("标记为已确认") {
                            item.needsConfirmation = false
                            item.confirmReason = nil
                        }
                    }
                }
            }
            .navigationTitle(item.kind == .event ? "编辑日程" : "编辑提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        syncResolvedCalendar()
                        dismiss()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var eventTimeSection: some View {
        Section("时间") {
            Toggle("全天", isOn: $item.isAllDay)

            DatePicker(
                "开始",
                selection: nonNil($item.startDate, default: Date()),
                displayedComponents: item.isAllDay ? [.date] : [.date, .hourAndMinute]
            )
            if !item.isAllDay {
                DatePicker(
                    "结束",
                    selection: nonNil($item.endDate,
                                      default: (item.startDate ?? Date()).addingTimeInterval(3600)),
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
        }
    }

    @ViewBuilder
    private var reminderTimeSection: some View {
        Section("截止时间") {
            Toggle("设置截止时间", isOn: Binding(
                get: { item.dueDate != nil },
                set: { item.dueDate = $0 ? (item.dueDate ?? Date()) : nil }
            ))
            if item.dueDate != nil {
                DatePicker(
                    "截止",
                    selection: nonNil($item.dueDate, default: Date()),
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
        }
    }

    private var emojiBinding: Binding<String> {
        Binding(get: { item.emoji ?? "" },
                set: { item.emoji = $0.isEmpty ? nil : $0 })
    }

    /// A `DatePicker` needs a non-optional binding; this supplies a default only
    /// while editing, without making the stored value non-optional.
    private func nonNil(_ source: Binding<Date?>, default fallback: Date) -> Binding<Date> {
        Binding(get: { source.wrappedValue ?? fallback },
                set: { source.wrappedValue = $0 })
    }

    /// Picking a calendar by name has to carry the identifier along, or the
    /// commit step falls back to title matching for no reason.
    private func syncResolvedCalendar() {
        item.resolvedCalendarID = availableCalendars
            .first { $0.title == item.calendarName }?
            .calendarIdentifier
    }
}
