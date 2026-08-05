import Foundation
import Testing

@testable import QuickAdd

/// This code shapes every record the app writes. A defect here is one the user
/// only meets months later while reading history back, so the format is pinned.
struct EventFormatterTests {

    static let sessionID = UUID(uuidString: "3F2504E0-4F89-41D3-9A0C-0305E82C3301")!

    static func item(
        kind: DraftItem.Kind = .event,
        title: String = "牙齿检查",
        emoji: String? = "🦷",
        details: String = "例行洗牙",
        direction: DraftItem.Direction = .past
    ) -> DraftItem {
        DraftItem(kind: kind, title: title, emoji: emoji, details: details,
                  calendarName: "个人", direction: direction)
    }

    static func formatter(
        template: String = AppSettings.defaultNotesTemplate,
        emojiInTitle: Bool = true
    ) -> EventFormatter {
        let settings = AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.notesTemplate = template
        settings.emojiInTitle = emojiInTitle
        return EventFormatter(settings: settings, modelId: "deepseek-v4-flash", appVersion: "v1.0.0")
    }

    // MARK: - Title

    @Test("Emoji is prefixed to the title when enabled")
    func emojiPrefixed() {
        #expect(Self.formatter().title(for: Self.item()) == "🦷 牙齿检查")
    }

    @Test("Title is left bare when the emoji setting is off")
    func emojiSuppressed() {
        #expect(Self.formatter(emojiInTitle: false).title(for: Self.item()) == "牙齿检查")
    }

    @Test("A missing emoji does not leave a leading space")
    func missingEmojiLeavesNoGap() {
        #expect(Self.formatter().title(for: Self.item(emoji: nil)) == "牙齿检查")
    }

    // MARK: - Notes

    @Test("Every placeholder is substituted")
    func placeholdersSubstituted() {
        let notes = Self.formatter().notes(
            for: Self.item(), sessionID: Self.sessionID,
            recordedAt: ISO8601.parse("2026-08-06T21:30:00+08:00")!)

        #expect(notes.contains("例行洗牙"))
        #expect(notes.contains("v1.0.0"))
        #expect(notes.contains("deepseek-v4-flash"))
        #expect(notes.contains("2026 年 08 月 06 日 21:30"))
        // No placeholder may survive into what the user actually reads.
        #expect(!notes.contains("{"))
    }

    @Test("session_id is substituted when the template asks for it")
    func sessionIDSubstituted() {
        let notes = Self.formatter(template: "{session_id}")
            .notes(for: Self.item(), sessionID: Self.sessionID)
        #expect(notes == Self.sessionID.uuidString)
    }

    @Test("Empty details do not leave the note starting with blank lines")
    func emptyDetailsTrimmed() {
        let notes = Self.formatter().notes(for: Self.item(details: ""), sessionID: Self.sessionID)
        #expect(!notes.hasPrefix("\n"))
        #expect(notes.hasPrefix("—"))
    }

    @Test("A template with no placeholders is passed through unchanged")
    func literalTemplate() {
        let notes = Self.formatter(template: "固定文本").notes(
            for: Self.item(), sessionID: Self.sessionID)
        #expect(notes == "固定文本")
    }

    // MARK: - Provenance URL

    @Test("The URL carries the session id and direction", arguments: [
        (DraftItem.Direction.past, "past"),
        (DraftItem.Direction.future, "future"),
    ])
    func urlCarriesDirection(direction: DraftItem.Direction, expected: String) throws {
        let url = try #require(
            Self.formatter().url(for: Self.item(direction: direction), sessionID: Self.sessionID))

        // Direction is embedded rather than looked up locally so origin survives
        // a reinstall — §7.1 grants destructive actions only to known origins.
        #expect(url.absoluteString
                == "quickadd://event/\(Self.sessionID.uuidString)?d=\(expected)")
    }

    @Test("The URL is parseable back into its parts")
    func urlRoundTrips() throws {
        let url = try #require(Self.formatter().url(for: Self.item(), sessionID: Self.sessionID))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))

        #expect(components.scheme == "quickadd")
        #expect(components.host == "event")
        #expect(components.path == "/\(Self.sessionID.uuidString)")
        #expect(components.queryItems?.first(where: { $0.name == "d" })?.value == "past")
    }
}
