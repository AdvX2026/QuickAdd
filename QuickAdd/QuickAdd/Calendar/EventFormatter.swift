import Foundation

/// Renders a draft into the fields EventKit will store (PRD §6.3).
///
/// Pure and value-typed so the format can be tested without touching the user's
/// real calendar — this code shapes every record the app ever writes, and a bug
/// here is one the user only discovers months later while reading back history.
struct EventFormatter {

    var template: String
    var emojiInTitle: Bool
    var appVersion: String
    var modelId: String

    static let urlScheme = "quickadd"

    init(settings: AppSettings, modelId: String, appVersion: String = EventFormatter.bundleVersion) {
        self.template = settings.notesTemplate
        self.emojiInTitle = settings.emojiInTitle
        self.appVersion = appVersion
        self.modelId = modelId
    }

    static var bundleVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return "v" + (short ?? "0.0.0")
    }

    func title(for item: DraftItem) -> String {
        guard emojiInTitle, let emoji = item.emoji, !emoji.isEmpty else { return item.title }
        return "\(emoji) \(item.title)"
    }

    func notes(for item: DraftItem, sessionID: UUID, recordedAt: Date = Date()) -> String {
        let replacements = [
            "{details}": item.details,
            "{app_version}": appVersion,
            "{timestamp}": Self.timestamp(recordedAt),
            "{model}": modelId,
            "{session_id}": sessionID.uuidString,
        ]
        var text = template
        for (token, value) in replacements {
            text = text.replacingOccurrences(of: token, with: value)
        }
        // An empty {details} leaves a run of blank lines at the top.
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Provenance identifier.
    ///
    /// `direction` is encoded in the URL rather than looked up locally so that
    /// origin survives a reinstall or a device change — the conflict rules in
    /// §7.1 grant destructive actions only against events of known origin, and
    /// an event that loses its origin silently loses those permissions.
    func url(for item: DraftItem, sessionID: UUID) -> URL? {
        var components = URLComponents()
        components.scheme = Self.urlScheme
        components.host = "event"
        components.path = "/\(sessionID.uuidString)"
        components.queryItems = [URLQueryItem(name: "d", value: item.direction.rawValue)]
        return components.url
    }

    private static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = .current
        f.dateFormat = "yyyy 年 MM 月 dd 日 HH:mm"
        return f.string(from: date)
    }
}
