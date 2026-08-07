import EventKit
import SwiftUI

struct SettingsView: View {

    @Environment(AppSettings.self) private var settings
    @Environment(CalendarStore.self) private var calendarStore
    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyField = ""
    @State private var keySaved = KeychainStore.hasAPIKey

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section {
                    LabeledContent("接口地址") {
                        TextField("baseURL", text: $settings.baseURL)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("模型") {
                        TextField("modelId", text: $settings.modelId)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    SecureField(keySaved ? "API Key（已保存）" : "API Key", text: $apiKeyField)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(saveKey)
                    if !apiKeyField.isEmpty {
                        Button("保存 Key", action: saveKey)
                    } else if keySaved {
                        Button("清除 Key", role: .destructive) {
                            KeychainStore.deleteAPIKey()
                            keySaved = false
                        }
                    }

                    Toggle("启用 thinking", isOn: $settings.thinkingEnabled)
                } header: {
                    Text("模型")
                } footer: {
                    Text("实测开启 thinking 后延迟约 38 秒，关闭后约 4 秒，抽取质量没有差别。除非要排查问题，建议保持关闭。")
                }

                calendarSection(
                    title: "日历（日程）",
                    configs: $settings.calendars,
                    defaultName: $settings.defaultCalendarName,
                    granted: calendarStore.hasEventAccess,
                    seeds: CalendarSetup.eventDefinitions,
                    preferredDefault: CalendarSetup.defaultEventCalendarTitle,
                    requestAccess: { await calendarStore.requestEventAccess() },
                    load: { calendarStore.writableCalendars() }
                )

                calendarSection(
                    title: "列表（提醒事项）",
                    configs: $settings.reminderLists,
                    defaultName: $settings.defaultReminderListName,
                    granted: calendarStore.hasReminderAccess,
                    requestAccess: { await calendarStore.requestReminderAccess() },
                    load: { calendarStore.writableReminderLists() }
                )

                Section("格式") {
                    Toggle("标题前加 Emoji", isOn: $settings.emojiInTitle)
                    NavigationLink("备注模板") {
                        NotesTemplateEditor(template: $settings.notesTemplate)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    // MARK: - Calendar mapping

    @ViewBuilder
    private func calendarSection(
        title: String,
        configs: Binding<[CalendarConfig]>,
        defaultName: Binding<String>,
        granted: Bool,
        seeds: [String: String] = [:],
        preferredDefault: String? = nil,
        requestAccess: @escaping () async -> Bool,
        load: @escaping () -> [EKCalendar]
    ) -> some View {
        let refresh = {
            merge(load(), into: configs, defaultName: defaultName,
                  seeds: seeds, preferredDefault: preferredDefault)
        }

        Section(title) {
            if !granted {
                Button("授权访问") {
                    Task {
                        if await requestAccess() { refresh() }
                    }
                }
            } else {
                if configs.wrappedValue.isEmpty {
                    Button("读取列表", action: refresh)
                } else {
                    ForEach(configs) { config in
                        NavigationLink {
                            CalendarDefinitionEditor(config: config)
                        } label: {
                            calendarRow(config)
                        }
                    }
                    Picker("默认归类", selection: defaultName) {
                        ForEach(configs.wrappedValue.filter(\.isEnabled)) { config in
                            Text(config.title).tag(config.title)
                        }
                    }
                    Button("重新读取", action: refresh)
                }
            }
        }
    }

    private func calendarRow(_ config: Binding<CalendarConfig>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Toggle(isOn: config.isEnabled) { Text(config.wrappedValue.title) }
                    .toggleStyle(.switch)
            }
            let definition = config.wrappedValue.definition
                .trimmingCharacters(in: .whitespacesAndNewlines)
            Text(definition.isEmpty ? "未填写说明，归类准确率会明显下降" : definition)
                .font(.caption)
                .foregroundStyle(definition.isEmpty ? .orange : .secondary)
                .lineLimit(2)
        }
    }

    private func merge(
        _ calendars: [EKCalendar],
        into configs: Binding<[CalendarConfig]>,
        defaultName: Binding<String>,
        seeds: [String: String],
        preferredDefault: String?
    ) {
        let merged = CalendarSetup.merge(
            discovered: calendars.map { ($0.calendarIdentifier, $0.title) },
            into: configs.wrappedValue,
            seeds: seeds)

        configs.wrappedValue = merged
        defaultName.wrappedValue = CalendarSetup.resolveDefault(
            current: defaultName.wrappedValue, among: merged, preferring: preferredDefault)
    }

    private func saveKey() {
        KeychainStore.saveAPIKey(apiKeyField)
        apiKeyField = ""
        keySaved = KeychainStore.hasAPIKey
    }
}

// MARK: - Definition editor

private struct CalendarDefinitionEditor: View {

    @Binding var config: CalendarConfig

    var body: some View {
        Form {
            Section {
                TextEditor(text: $config.definition)
                    .frame(minHeight: 160)
            } header: {
                Text("「\(config.title)」放什么")
            } footer: {
                Text("""
                写清楚边界，尤其是「不包括什么」——反例对归类准确率的帮助比正例大得多。

                例：
                个人：健康就医、理财、证件办理、个人成长。
                不包括 → 和朋友的活动（那属于 生活）、公司组织的体检（那属于 工作）
                """)
            }
        }
        .navigationTitle(config.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Notes template

private struct NotesTemplateEditor: View {

    @Binding var template: String

    var body: some View {
        Form {
            Section {
                TextEditor(text: $template)
                    .frame(minHeight: 140)
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("写入日历的备注")
            } footer: {
                Text("""
                可用占位符：
                {details} 详细描述　{app_version} 版本号
                {timestamp} 记录时间　{model} 模型名
                {session_id} 本次记录编号
                """)
            }

            Section {
                Button("恢复默认") { template = AppSettings.defaultNotesTemplate }
            }
        }
        .navigationTitle("备注模板")
        .navigationBarTitleDisplayMode(.inline)
    }
}
