import Foundation
import Observation

/// One of the user's calendars (or reminder lists), plus the description that
/// teaches the model what belongs in it.
///
/// Both the identifier and the title are stored: identifiers are stable in
/// normal use but can be invalidated by an account re-login or a re-sync, and
/// falling back to the title recovers the mapping without making the user
/// reconfigure everything (PRD §6.2).
struct CalendarConfig: Codable, Identifiable, Hashable {
    var calendarIdentifier: String
    var title: String
    /// Injected verbatim into the prompt. Boundary counter-examples matter more
    /// than positive examples here — see PRD §6.1.
    var definition: String = ""
    var isEnabled: Bool = true

    var id: String { calendarIdentifier }
}

@Observable
final class AppSettings {

    // MARK: Model

    var baseURL: String { didSet { store(baseURL, .baseURL) } }
    var modelId: String { didSet { store(modelId, .modelId) } }
    /// Off by default: measured at 38.5s versus 3.6s with no quality gain
    /// (PRD §8.2).
    var thinkingEnabled: Bool { didSet { store(thinkingEnabled, .thinkingEnabled) } }

    // MARK: Calendars

    var calendars: [CalendarConfig] { didSet { storeJSON(calendars, .calendars) } }
    var defaultCalendarName: String { didSet { store(defaultCalendarName, .defaultCalendarName) } }

    var reminderLists: [CalendarConfig] { didSet { storeJSON(reminderLists, .reminderLists) } }
    var defaultReminderListName: String { didSet { store(defaultReminderListName, .defaultReminderListName) } }

    // MARK: Formatting

    var emojiInTitle: Bool { didSet { store(emojiInTitle, .emojiInTitle) } }
    var notesTemplate: String { didSet { store(notesTemplate, .notesTemplate) } }

    // MARK: Defaults

    static let defaultBaseURL = "https://api.deepseek.com"
    static let defaultModelId = "deepseek-v4-flash"
    static let defaultNotesTemplate = """
        {details}

        —
        由 QuickAdd {app_version} 于 {timestamp} 记录，模型 {model}
        """

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        baseURL = defaults.string(forKey: Key.baseURL.rawValue) ?? Self.defaultBaseURL
        modelId = defaults.string(forKey: Key.modelId.rawValue) ?? Self.defaultModelId
        thinkingEnabled = defaults.bool(forKey: Key.thinkingEnabled.rawValue)

        calendars = Self.loadJSON([CalendarConfig].self, .calendars, from: defaults) ?? []
        defaultCalendarName = defaults.string(forKey: Key.defaultCalendarName.rawValue) ?? ""
        reminderLists = Self.loadJSON([CalendarConfig].self, .reminderLists, from: defaults) ?? []
        defaultReminderListName = defaults.string(forKey: Key.defaultReminderListName.rawValue) ?? ""

        emojiInTitle = defaults.object(forKey: Key.emojiInTitle.rawValue) as? Bool ?? true
        notesTemplate = defaults.string(forKey: Key.notesTemplate.rawValue) ?? Self.defaultNotesTemplate
    }

    // MARK: Derived

    var enabledCalendars: [CalendarConfig] { calendars.filter(\.isEnabled) }
    var enabledReminderLists: [CalendarConfig] { reminderLists.filter(\.isEnabled) }

    /// Name → identifier map for the validator (PRD §5.4).
    func calendarsByName(for kind: DraftItem.Kind) -> [String: String] {
        let source = kind == .event ? enabledCalendars : enabledReminderLists
        return Dictionary(source.map { ($0.title, $0.calendarIdentifier) },
                          uniquingKeysWith: { first, _ in first })
    }

    func defaultName(for kind: DraftItem.Kind) -> String {
        kind == .event ? defaultCalendarName : defaultReminderListName
    }

    /// The app cannot extract anything useful until calendars are mapped and a
    /// key exists, so the UI needs a single place to ask.
    var isConfigured: Bool {
        !enabledCalendars.isEmpty && !defaultCalendarName.isEmpty
    }

    // MARK: Persistence

    private enum Key: String {
        case baseURL, modelId, thinkingEnabled
        case calendars, defaultCalendarName
        case reminderLists, defaultReminderListName
        case emojiInTitle, notesTemplate
    }

    private func store(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    private func storeJSON<T: Encodable>(_ value: T, _ key: Key) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key.rawValue)
    }

    private static func loadJSON<T: Decodable>(
        _ type: T.Type, _ key: Key, from defaults: UserDefaults
    ) -> T? {
        guard let data = defaults.data(forKey: key.rawValue) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
