import SwiftData
import SwiftUI

/// Every capture ever made, including the ones that failed.
///
/// This is the visible half of the "never lose a record" guarantee — if the
/// input made it to disk, it shows up here regardless of what happened next.
struct LogView: View {

    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CaptureSession.createdAt, order: .reverse) private var sessions: [CaptureSession]

    var body: some View {
        NavigationStack {
            List {
                ForEach(sessions) { session in
                    NavigationLink {
                        LogDetailView(session: session)
                    } label: {
                        LogRow(session: session)
                    }
                }
            }
            .overlay {
                if sessions.isEmpty {
                    ContentUnavailableView("还没有记录", systemImage: "clock")
                }
            }
            .navigationTitle("日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct LogRow: View {
    let session: CaptureSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.rawText)
                .lineLimit(2)
                .font(.body)
            HStack(spacing: 6) {
                Text(session.createdAt, format: .dateTime.month().day().hour().minute())
                Text("·")
                StatusBadge(status: session.status)
                if !session.items.isEmpty {
                    Text("· \(session.items.count) 项")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct StatusBadge: View {
    let status: CaptureSession.Status

    var body: some View {
        Text(label)
            .foregroundStyle(tint)
    }

    private var label: String {
        switch status {
        case .draft:      "未处理"
        case .extracting: "整理中"
        case .reviewing:  "待确认"
        case .committed:  "已添加"
        case .failed:     "失败"
        }
    }

    private var tint: Color {
        switch status {
        case .committed: .green
        case .failed:    .red
        case .reviewing: .orange
        default:         .secondary
        }
    }
}

private struct LogDetailView: View {
    let session: CaptureSession

    var body: some View {
        List {
            Section("原始输入") {
                Text(session.rawText)
                    .textSelection(.enabled)
            }

            if let error = session.errorMessage {
                Section("错误") {
                    Text(error).foregroundStyle(.red)
                }
            }

            if !session.items.isEmpty {
                Section("整理结果") {
                    ForEach(session.items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(item.emoji.map { $0 + " " } ?? "")\(item.title)")
                            HStack(spacing: 6) {
                                Text(item.kind == .event ? "日程" : "提醒")
                                Text("·")
                                Text(item.calendarName)
                                Text("·")
                                Text(item.direction == .past ? "回记" : "规划")
                                if item.committedIdentifier != nil {
                                    Text("· 已写入").foregroundStyle(.green)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("元信息") {
                LabeledContent("时间", value: session.createdAt.formatted())
                if let model = session.modelId {
                    LabeledContent("模型", value: model)
                }
                LabeledContent("编号", value: session.id.uuidString)
                    .font(.caption)
            }

            // Kept because it is the only evidence available when an extraction
            // goes wrong and the prompt needs adjusting.
            if let raw = session.llmRawResponse {
                Section("模型原始返回") {
                    Text(raw)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("记录详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}
