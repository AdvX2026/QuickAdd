import Foundation
import Observation
import SwiftData

/// Drives one capture from raw text to committed calendar entries.
///
/// The ordering here is the whole point: the session is written to disk with the
/// user's text *before* the network call goes out. A crash, a dead connection,
/// or a model failure then costs a retry, never the input.
@Observable
@MainActor
final class CaptureCoordinator {

    enum Phase: Equatable {
        case idle
        case extracting
        case reviewing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var currentSession: CaptureSession?
    private(set) var lastCommitMessage: String?

    private let context: ModelContext
    private let settings: AppSettings
    private let calendarStore: CalendarStore

    init(context: ModelContext, settings: AppSettings, calendarStore: CalendarStore) {
        self.context = context
        self.settings = settings
        self.calendarStore = calendarStore
    }

    var isBusy: Bool { phase == .extracting }

    // MARK: - Capture

    func submit(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Step one, before anything can fail: persist the input.
        let session = CaptureSession(rawText: trimmed)
        context.insert(session)
        save()

        currentSession = session
        await runExtraction(on: session)
    }

    /// Re-runs extraction against an existing session. The raw text is already
    /// safe on disk, which is what makes retrying free.
    func retry(_ session: CaptureSession) async {
        currentSession = session
        session.items.forEach(context.delete)
        session.items = []
        session.errorMessage = nil
        await runExtraction(on: session)
    }

    private func runExtraction(on session: CaptureSession) async {
        phase = .extracting
        session.status = .extracting
        save()

        let provider = OpenAICompatibleProvider(settings: settings)

        do {
            let outcome = try await provider.extract(input: session.rawText)

            session.llmRawResponse = outcome.rawContent
            session.modelId = outcome.modelId

            let items = buildItems(from: outcome.response)
            for item in items {
                item.session = session
                context.insert(item)
            }
            session.items = items
            session.status = .reviewing
            session.errorMessage = nil
            save()

            phase = .reviewing
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            session.status = .failed
            session.errorMessage = message
            save()
            phase = .failed(message)
        }
    }

    private func buildItems(from response: ExtractionResponse) -> [DraftItem] {
        ExtractionValidator.validate(response, context: .init(
            calendarsByName: settings.calendarsByName(for: .event),
            defaultCalendarName: settings.defaultCalendarName,
            reminderListsByName: settings.calendarsByName(for: .reminder),
            defaultReminderListName: settings.defaultReminderListName
        )).items
    }

    // MARK: - Commit

    func commitSelected(in session: CaptureSession) async {
        // Asking here rather than at launch means the permission sheet appears
        // attached to an action the user just took (PRD §9). No-op once granted.
        await requestAccessIfNeeded(for: session)

        guard hasRequiredAccess(for: session) else {
            lastCommitMessage = "未获得日历权限，无法写入"
            return
        }

        let formatter = EventFormatter(settings: settings, modelId: session.modelId ?? settings.modelId)
        let report = calendarStore.commit(
            items: session.items, sessionID: session.id, formatter: formatter)

        if !report.written.isEmpty {
            session.status = .committed
        }
        save()

        lastCommitMessage = summary(of: report)
    }

    private func requestAccessIfNeeded(for session: CaptureSession) async {
        let needs = requirements(for: session)

        if needs.events, !calendarStore.hasEventAccess {
            await calendarStore.requestEventAccess()
        }
        if needs.reminders, !calendarStore.hasReminderAccess {
            await calendarStore.requestReminderAccess()
        }
    }

    /// Only the permissions this batch actually needs. A session of pure
    /// reminders should not be blocked by a declined calendar prompt.
    private func hasRequiredAccess(for session: CaptureSession) -> Bool {
        let needs = requirements(for: session)
        if needs.events, !calendarStore.hasEventAccess { return false }
        if needs.reminders, !calendarStore.hasReminderAccess { return false }
        return needs.events || needs.reminders
    }

    private func requirements(for session: CaptureSession) -> (events: Bool, reminders: Bool) {
        let selected = session.items.filter { $0.isSelected && $0.committedIdentifier == nil }
        return (selected.contains { $0.kind == .event },
                selected.contains { $0.kind == .reminder })
    }

    private func summary(of report: CalendarStore.CommitReport) -> String {
        var parts: [String] = []
        if !report.written.isEmpty { parts.append("已添加 \(report.written.count) 项") }
        if report.skipped > 0 { parts.append("跳过 \(report.skipped) 项已添加") }
        if !report.failures.isEmpty {
            parts.append("\(report.failures.count) 项失败：\(report.failures[0].message)")
        }
        return parts.isEmpty ? "没有可添加的条目" : parts.joined(separator: "，")
    }

    // MARK: - Session lifecycle

    func discard(_ session: CaptureSession) {
        context.delete(session)
        save()
        if currentSession?.id == session.id {
            currentSession = nil
            phase = .idle
        }
    }

    func finish() {
        currentSession = nil
        phase = .idle
        lastCommitMessage = nil
    }

    private func save() {
        do {
            try context.save()
        } catch {
            // A failed save here means the capture is no longer protected, which
            // is the one thing this class exists to prevent. Surface it.
            phase = .failed("本地保存失败：\(error.localizedDescription)")
        }
    }
}
