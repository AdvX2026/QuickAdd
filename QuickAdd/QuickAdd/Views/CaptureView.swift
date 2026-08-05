import SwiftUI

/// The main screen: a greeting, then whatever the current capture has produced,
/// over a persistent input bar.
struct CaptureView: View {

    @Environment(AppSettings.self) private var settings

    let coordinator: CaptureCoordinator

    @State private var text = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
                .onTapGesture { inputFocused = false }

            InputBar(
                text: $text,
                isFocused: $inputFocused,
                isBusy: coordinator.isBusy,
                onSend: send
            )
        }
        .background(.background)
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .idle:
            if settings.isConfigured {
                GreetingView()
            } else {
                SetupPromptView()
            }

        case .extracting:
            VStack(spacing: 16) {
                ProgressView()
                Text("正在整理…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

        case .reviewing:
            if let session = coordinator.currentSession {
                ReviewView(session: session, coordinator: coordinator)
            }

        case .failed(let message):
            FailureView(message: message, coordinator: coordinator)
        }
    }

    private func send() {
        let payload = text
        text = ""
        inputFocused = false
        Task { await coordinator.submit(payload) }
    }
}

// MARK: - Input bar

private struct InputBar: View {

    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let isBusy: Bool
    let onSend: () -> Void

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                TextField("说点什么…", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($isFocused)
                    .submitLabel(.send)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .glassEffect(.regular, in: .rect(cornerRadius: 22))

                // The send button sits where the mic button will go in M1; the
                // layout is already the final one so voice slots straight in.
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glassProminent)
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - Idle states

private struct GreetingView: View {
    var body: some View {
        VStack(spacing: 10) {
            Text(Self.greeting)
                .font(.title2.weight(.medium))
            Text("说说你做了什么，或者打算做什么")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
    }

    private static var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<11:  return "早上好"
        case 11..<14: return "中午好"
        case 14..<18: return "下午好"
        case 18..<23: return "晚上好"
        default:      return "还没睡？"
        }
    }
}

private struct SetupPromptView: View {
    var body: some View {
        ContentUnavailableView {
            Label("还没配置日历", systemImage: "calendar.badge.exclamationmark")
        } description: {
            Text("到设置里选择要使用的日历，并说明每个日历放什么内容。\n描述得越清楚，归类越准。")
        }
        .padding(.horizontal, 24)
    }
}

private struct FailureView: View {
    let message: String
    let coordinator: CaptureCoordinator

    var body: some View {
        ContentUnavailableView {
            Label("整理失败", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 12) {
                Text(message)
                // The input is already on disk, so retrying costs nothing and
                // the user never has to say it again.
                if let session = coordinator.currentSession {
                    Text("「\(session.rawText)」")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        } actions: {
            if let session = coordinator.currentSession {
                Button("重试") {
                    Task { await coordinator.retry(session) }
                }
                .buttonStyle(.glassProminent)
            }
        }
        .padding(.horizontal, 24)
    }
}
