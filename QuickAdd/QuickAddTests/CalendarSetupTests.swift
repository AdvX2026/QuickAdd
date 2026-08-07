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
        _ discovered: [(identifier: String, title: String)],
        into existing: [CalendarConfig] = [],
        seeds: [String: String] = CalendarSetupTests.seeds
    ) -> [CalendarConfig] {
        CalendarSetup.merge(discovered: discovered, into: existing, seeds: seeds)
    }

    // MARK: - Seeding

    @Test("A newly discovered calendar picks up the seeded definition")
    func newCalendarIsSeeded() throws {
        let merged = Self.merge([("id-work", "工作")])

        let config = try #require(merged.first)
        #expect(config.definition == Self.seeds["工作"])
        #expect(config.isEnabled)
    }

    @Test("A title with no seed is left blank rather than guessed at")
    func unknownTitleGetsNoDefinition() throws {
        let merged = Self.merge([("id-x", "读书会")])

        #expect(merged.first?.definition.isEmpty == true)
    }

    @Test("Reminder lists pass an empty seed table and stay blank")
    func emptySeedTableSeedsNothing() throws {
        let merged = Self.merge([("id-r", "工作")], seeds: [:])

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

        let merged = Self.merge([("id-work", "工作")], into: existing)

        #expect(merged.first?.definition == "我自己写的说明")
    }

    @Test("A blank definition is re-seeded on the next refresh")
    func blankDefinitionIsFilled() throws {
        // Whitespace counts as blank: an empty field is never a deliberate
        // choice — the row shows a warning in that state.
        let existing = [CalendarConfig(
            calendarIdentifier: "id-work", title: "工作", definition: "  \n ")]

        let merged = Self.merge([("id-work", "工作")], into: existing)

        #expect(merged.first?.definition == Self.seeds["工作"])
    }

    @Test("isEnabled survives a refresh")
    func disabledStateIsPreserved() throws {
        let existing = [CalendarConfig(
            calendarIdentifier: "id-sleep", title: "睡眠", definition: "", isEnabled: false)]

        let merged = Self.merge([("id-sleep", "睡眠")], into: existing)

        #expect(merged.first?.isEnabled == false)
    }

    // MARK: - Renames and removals

    @Test("A rename in Calendar.app updates the title and keeps the definition")
    func renamePreservesDefinition() throws {
        let existing = [CalendarConfig(
            calendarIdentifier: "id-work", title: "工作", definition: "我自己写的说明")]

        let merged = Self.merge([("id-work", "Work")], into: existing)

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

        let merged = Self.merge([("id-work", "工作")], into: existing)

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

    @Test("Without the preferred calendar the first enabled one is used")
    func fallsBackToFirstEnabled() {
        let configs = [
            CalendarConfig(calendarIdentifier: "id-off", title: "关掉的", isEnabled: false),
            CalendarConfig(calendarIdentifier: "id-work", title: "工作"),
        ]

        let resolved = CalendarSetup.resolveDefault(
            current: "不存在", among: configs, preferring: "日历")

        #expect(resolved == "工作")
    }

    @Test("A disabled calendar cannot be the default")
    func disabledCannotBeDefault() {
        let configs = [CalendarConfig(
            calendarIdentifier: "id-cal", title: "日历", isEnabled: false)]

        let resolved = CalendarSetup.resolveDefault(
            current: "日历", among: configs, preferring: "日历")

        #expect(resolved.isEmpty)
    }
}
