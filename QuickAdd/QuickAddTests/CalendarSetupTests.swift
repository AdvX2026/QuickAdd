import Foundation
import Testing

@testable import QuickAdd

/// The seeded definitions are a convenience; the invariant that matters is that
/// seeding can only ever *add* text. A definition the user wrote by hand is the
/// most expensive thing in settings, and losing one on a routine "重新读取" would
/// be silent.
struct CalendarSetupTests {

    static let seeds = CalendarSetup.eventDefinitions

    static func merge(
        _ discovered: [(identifier: String, title: String, sourceTitle: String)],
        into existing: [CalendarConfig] = [],
        seeds: [String: String] = CalendarSetupTests.seeds
    ) -> [CalendarConfig] {
        CalendarSetup.merge(discovered: discovered, into: existing, seeds: seeds)
    }

    // MARK: - Seeding

    @Test("A newly discovered calendar picks up the seeded definition")
    func newCalendarIsSeeded() throws {
        let merged = Self.merge([("id-work", "工作", "iCloud")])

        let config = try #require(merged.first)
        #expect(config.definition == Self.seeds["工作"])
        #expect(config.isEnabled)
    }

    @Test("A title with no seed is left blank rather than guessed at")
    func unknownTitleGetsNoDefinition() throws {
        let merged = Self.merge([("id-x", "读书会", "iCloud")])

        #expect(merged.first?.definition.isEmpty == true)
    }

    @Test("Reminder lists pass an empty seed table and stay blank")
    func emptySeedTableSeedsNothing() throws {
        let merged = Self.merge([("id-r", "工作", "iCloud")], seeds: [:])

        #expect(merged.first?.definition.isEmpty == true)
    }

    // 睡眠 and 日历 are one-liners by design; the six substantive ones each have
    // to say what they exclude, which is what made classification stable.
    @Test("Every substantive definition states a test and a counter-example",
          arguments: ["工作", "创意", "学习", "个人", "生活", "旅行"])
    func seedsCarryADecidableTest(title: String) throws {
        let definition = try #require(CalendarSetup.eventDefinitions[title])

        #expect(definition.contains("判断标准"))
        #expect(definition.contains("不包括"))
    }

    // MARK: - Never overwrite

    @Test("A definition the user wrote survives a refresh untouched")
    func userDefinitionIsPreserved() throws {
        let existing = [CalendarConfig(
            calendarIdentifier: "id-work", title: "工作", definition: "我自己写的说明")]

        let merged = Self.merge([("id-work", "工作", "iCloud")], into: existing)

        #expect(merged.first?.definition == "我自己写的说明")
    }

    @Test("A blank definition is re-seeded on the next refresh")
    func blankDefinitionIsFilled() throws {
        // Whitespace counts as blank: an empty field is never a deliberate
        // choice — the row shows a warning in that state.
        let existing = [CalendarConfig(
            calendarIdentifier: "id-work", title: "工作", definition: "  \n ")]

        let merged = Self.merge([("id-work", "工作", "iCloud")], into: existing)

        #expect(merged.first?.definition == Self.seeds["工作"])
    }

    @Test("isEnabled survives a refresh")
    func disabledStateIsPreserved() throws {
        let existing = [CalendarConfig(
            calendarIdentifier: "id-sleep", title: "睡眠", definition: "", isEnabled: false)]

        let merged = Self.merge([("id-sleep", "睡眠", "iCloud")], into: existing)

        #expect(merged.first?.isEnabled == false)
    }

    // MARK: - Renames and removals

    @Test("A rename in Calendar.app updates the title and keeps the definition")
    func renamePreservesDefinition() throws {
        let existing = [CalendarConfig(
            calendarIdentifier: "id-work", title: "工作", definition: "我自己写的说明")]

        let merged = Self.merge([("id-work", "Work", "iCloud")], into: existing)

        let config = try #require(merged.first)
        #expect(config.title == "Work")
        #expect(config.definition == "我自己写的说明")
    }

    @Test("A calendar that no longer exists is dropped")
    func removedCalendarDisappears() {
        let existing = [
            CalendarConfig(calendarIdentifier: "id-work", title: "工作"),
            CalendarConfig(calendarIdentifier: "id-gone", title: "已删除"),
        ]

        let merged = Self.merge([("id-work", "工作", "iCloud")], into: existing)

        #expect(merged.map(\.calendarIdentifier) == ["id-work"])
    }

    // MARK: - Default resolution

    @Test("The user's current default is kept while it still exists")
    func currentDefaultWins() {
        let configs = [
            CalendarConfig(calendarIdentifier: "id-work", title: "工作"),
            CalendarConfig(calendarIdentifier: "id-cal", title: "日历"),
        ]

        let resolved = CalendarSetup.resolveDefault(
            current: "工作", among: configs, preferring: "日历")

        #expect(resolved == "工作")
    }

    @Test("An absent default falls back to the preferred calendar, not to whatever is first")
    func preferredDefaultBeatsOrdering() {
        let configs = [
            CalendarConfig(calendarIdentifier: "id-work", title: "工作"),
            CalendarConfig(calendarIdentifier: "id-cal", title: "日历"),
        ]

        let resolved = CalendarSetup.resolveDefault(
            current: "", among: configs, preferring: CalendarSetup.defaultEventCalendarTitle)

        #expect(resolved == "日历")
    }

    @Test("With no catch-all calendar the default is left unset, not guessed")
    func noCatchAllLeavesDefaultUnset() {
        // Someone whose calendars are 创意/工作/生活 has no 日历. Picking one of
        // those would quietly turn a category calendar into the bucket every
        // unclassifiable item falls into.
        let configs = [
            CalendarConfig(calendarIdentifier: "id-idea", title: "创意"),
            CalendarConfig(calendarIdentifier: "id-work", title: "工作"),
        ]

        let resolved = CalendarSetup.resolveDefault(
            current: "不存在", among: configs, preferring: "日历")

        #expect(resolved.isEmpty)
    }

    @Test("An unset default reads as unconfigured so the user is asked")
    func unsetDefaultIsNotConfigured() {
        let settings = AppSettingsAmbiguityTests.settings { $0.defaultCalendarName = "" }

        #expect(!settings.isConfigured)
    }

    @Test("A disabled calendar cannot be the default")
    func disabledCannotBeDefault() {
        let configs = [CalendarConfig(
            calendarIdentifier: "id-cal", title: "日历", isEnabled: false)]

        let resolved = CalendarSetup.resolveDefault(
            current: "日历", among: configs, preferring: "日历")

        #expect(resolved.isEmpty)
    }

    @Test("An ambiguous title is never chosen as the default")
    func ambiguousTitleCannotBeDefault() {
        let configs = [
            CalendarConfig(calendarIdentifier: "id-a", title: "工作", sourceTitle: "iCloud"),
            CalendarConfig(calendarIdentifier: "id-b", title: "工作", sourceTitle: "Gmail"),
            CalendarConfig(calendarIdentifier: "id-cal", title: "日历"),
        ]

        // Even when the user's stored default *is* 工作, it stops being an answer
        // the moment a second account supplies one.
        let resolved = CalendarSetup.resolveDefault(
            current: "工作", among: configs, preferring: "日历")

        #expect(resolved == "日历")
    }
}

// MARK: - Duplicate titles across accounts

/// A calendar title is unique only inside one account. Two accounts can both
/// supply 工作, and every layer downstream keys off the title, so the pipeline
/// has to refuse the name rather than pick a calendar the user never chose.
struct CalendarAmbiguityTests {

    static func duplicated(enabled: Bool = true) -> [CalendarConfig] {
        [
            CalendarConfig(calendarIdentifier: "id-a", title: "工作",
                           sourceTitle: "iCloud", isEnabled: true),
            CalendarConfig(calendarIdentifier: "id-b", title: "工作",
                           sourceTitle: "Gmail", isEnabled: enabled),
            CalendarConfig(calendarIdentifier: "id-cal", title: "日历",
                           sourceTitle: "iCloud"),
        ]
    }

    @Test("A title two enabled calendars share is reported as ambiguous")
    func duplicateEnabledTitleIsAmbiguous() {
        #expect(CalendarSetup.ambiguousTitles(among: Self.duplicated()) == ["工作"])
    }

    @Test("Disabling one copy resolves the ambiguity")
    func disablingOneCopyResolvesIt() {
        #expect(CalendarSetup.ambiguousTitles(among: Self.duplicated(enabled: false)).isEmpty)
    }

    @Test("An ambiguous title drops out of the usable set entirely")
    func ambiguousTitleIsNotUsable() {
        // Both copies go, not just one: keeping either would be the silent
        // arbitrary pick this whole rule exists to prevent.
        let usable = CalendarSetup.usable(Self.duplicated())

        #expect(usable.map(\.title) == ["日历"])
    }

    @Test("Once the ambiguity is resolved the surviving calendar is usable again")
    func resolvedTitleBecomesUsable() {
        let usable = CalendarSetup.usable(Self.duplicated(enabled: false))

        #expect(usable.map(\.calendarIdentifier) == ["id-a", "id-cal"])
    }

    // MARK: Discovery

    @Test("Calendars discovered with a colliding title start disabled")
    func collidingDiscoveryStartsDisabled() {
        let merged = CalendarSetup.merge(
            discovered: [("id-a", "工作", "iCloud"),
                         ("id-b", "工作", "Gmail"),
                         ("id-cal", "日历", "iCloud")],
            into: [],
            seeds: CalendarSetup.eventDefinitions)

        #expect(merged.filter { $0.title == "工作" }.allSatisfy { !$0.isEnabled })
        #expect(merged.first { $0.title == "日历" }?.isEnabled == true)
    }

    @Test("A tie the user already broke is not re-broken on refresh")
    func existingChoiceSurvivesRediscovery() {
        // The user picked the iCloud one; a later "重新读取" must not undo that.
        let existing = [
            CalendarConfig(calendarIdentifier: "id-a", title: "工作",
                           sourceTitle: "iCloud", isEnabled: true),
            CalendarConfig(calendarIdentifier: "id-b", title: "工作",
                           sourceTitle: "Gmail", isEnabled: false),
        ]

        let merged = CalendarSetup.merge(
            discovered: [("id-a", "工作", "iCloud"), ("id-b", "工作", "Gmail")],
            into: existing,
            seeds: [:])

        #expect(merged.first { $0.calendarIdentifier == "id-a" }?.isEnabled == true)
        #expect(merged.first { $0.calendarIdentifier == "id-b" }?.isEnabled == false)
    }

    @Test("A newly synced account cannot quietly join an existing title")
    func newAccountArrivesDisabled() {
        let existing = [CalendarConfig(calendarIdentifier: "id-a", title: "工作",
                                       sourceTitle: "iCloud", isEnabled: true)]

        let merged = CalendarSetup.merge(
            discovered: [("id-a", "工作", "iCloud"), ("id-b", "工作", "Exchange")],
            into: existing,
            seeds: [:])

        #expect(merged.first { $0.calendarIdentifier == "id-a" }?.isEnabled == true)
        #expect(merged.first { $0.calendarIdentifier == "id-b" }?.isEnabled == false)
    }

    @Test("The account name is refreshed from EventKit, never used as identity")
    func sourceTitleIsRefreshed() throws {
        let existing = [CalendarConfig(calendarIdentifier: "id-a", title: "工作",
                                       sourceTitle: "旧账户名")]

        let merged = CalendarSetup.merge(
            discovered: [("id-a", "工作", "iCloud")], into: existing, seeds: [:])

        let config = try #require(merged.first)
        #expect(config.sourceTitle == "iCloud")
        #expect(config.calendarIdentifier == "id-a")
    }
}

// MARK: - Stored config survives schema changes

/// `AppSettings.loadJSON` decodes with `try?`, so a decode failure reads as
/// "nothing configured" and silently discards every calendar the user set up.
/// The synthesized decoder throws on a missing key rather than using the
/// property default, which made adding one field a data-loss bug.
struct CalendarConfigCodableTests {

    static func decode(_ json: String) throws -> CalendarConfig {
        try JSONDecoder().decode(CalendarConfig.self, from: Data(json.utf8))
    }

    @Test("Config written before sourceTitle existed still decodes")
    func decodesWithoutSourceTitle() throws {
        let config = try Self.decode("""
        {"calendarIdentifier":"id-a","title":"工作",
         "definition":"我自己写的说明","isEnabled":true}
        """)

        #expect(config.sourceTitle.isEmpty)
        #expect(config.definition == "我自己写的说明")
        #expect(config.isEnabled)
    }

    @Test("Only the identity fields are actually required")
    func decodesWithIdentityOnly() throws {
        let config = try Self.decode("""
        {"calendarIdentifier":"id-a","title":"工作"}
        """)

        #expect(config.definition.isEmpty)
        // Defaulting to enabled matches a freshly discovered calendar.
        #expect(config.isEnabled)
    }

    @Test("A round trip preserves every field")
    func roundTrips() throws {
        let original = CalendarConfig(
            calendarIdentifier: "id-a", title: "工作",
            sourceTitle: "Gmail", definition: "说明", isEnabled: false)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CalendarConfig.self, from: data)

        #expect(decoded == original)
    }
}

// MARK: - End of the chain

/// The tests above cover the rule; these cover the two places the rule has to
/// actually take effect, because this is where a duplicated title used to turn
/// into an event written to somebody else's account.
struct AppSettingsAmbiguityTests {

    static func settings(_ body: (AppSettings) -> Void) -> AppSettings {
        let name = "AppSettingsAmbiguityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        let settings = AppSettings(defaults: defaults)
        settings.calendars = [
            CalendarConfig(calendarIdentifier: "id-a", title: "工作", sourceTitle: "iCloud"),
            CalendarConfig(calendarIdentifier: "id-b", title: "工作", sourceTitle: "Gmail"),
            CalendarConfig(calendarIdentifier: "id-cal", title: "日历", sourceTitle: "iCloud"),
        ]
        body(settings)
        return settings
    }

    @Test("The validator is never handed a name that resolves two ways")
    func ambiguousNameIsNotResolvable() {
        let settings = Self.settings { $0.defaultCalendarName = "日历" }

        let names = settings.calendarsByName(for: .event)
        #expect(names["工作"] == nil)
        #expect(names["日历"] == "id-cal")
    }

    @Test("A default that became ambiguous counts as unconfigured")
    func ambiguousDefaultBlocksConfiguration() {
        // Unclassifiable items fall back to the default, so if the default
        // itself has two answers there is nowhere safe to put them.
        let settings = Self.settings { $0.defaultCalendarName = "工作" }

        #expect(!settings.isConfigured)
    }

    @Test("An unambiguous default is configured as usual")
    func unambiguousDefaultIsConfigured() {
        let settings = Self.settings { $0.defaultCalendarName = "日历" }

        #expect(settings.isConfigured)
    }
}
