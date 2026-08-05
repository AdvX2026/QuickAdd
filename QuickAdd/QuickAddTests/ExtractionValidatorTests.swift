import Foundation
import Testing

@testable import QuickAdd

/// Covers PRD §5.4 in full. These rules are the only thing standing between a
/// model that "guarantees valid JSON but not valid structure" and the user's
/// real calendar, so every row of that table gets a case.
struct ExtractionValidatorTests {

    // A fixed clock keeps "is this in the past" assertions from drifting.
    static let now = ISO8601.parse("2026-08-06T12:00:00+08:00")!

    static func context(
        calendars: [String: String] = ["工作": "cal-work", "生活": "cal-life", "个人": "cal-personal"],
        defaultCalendar: String = "生活"
    ) -> ExtractionValidator.Context {
        .init(calendarsByName: calendars, defaultCalendarName: defaultCalendar, now: now)
    }

    static func decode(_ json: String) throws -> ExtractionResponse {
        try JSONDecoder().decode(ExtractionResponse.self, from: Data(json.utf8))
    }

    static func validate(_ json: String) throws -> ExtractionValidator.Result {
        ExtractionValidator.validate(try decode(json), context: context())
    }

    // MARK: - Calendar resolution

    @Test("Unknown calendar falls back to the default and flags the card")
    func unknownCalendarFallsBack() throws {
        let result = try Self.validate("""
        {"events":[{"title":"看展","calendar":"学习",
          "start":"2026-08-06T10:00:00+08:00","end":"2026-08-06T11:00:00+08:00",
          "direction":"past"}],"reminders":[]}
        """)

        let item = try #require(result.items.first)
        #expect(item.calendarName == "生活")
        #expect(item.resolvedCalendarID == "cal-life")
        #expect(item.needsConfirmation)
        #expect(item.confirmReason?.contains("学习") == true)
    }

    @Test("Known calendar resolves to its identifier without flagging")
    func knownCalendarResolves() throws {
        let result = try Self.validate("""
        {"events":[{"title":"例会","calendar":"工作",
          "start":"2026-08-06T09:00:00+08:00","end":"2026-08-06T10:00:00+08:00",
          "direction":"past"}],"reminders":[]}
        """)

        let item = try #require(result.items.first)
        #expect(item.resolvedCalendarID == "cal-work")
        #expect(!item.needsConfirmation)
    }

    @Test("A missing calendar field is treated the same as an unknown one")
    func missingCalendarFallsBack() throws {
        let result = try Self.validate("""
        {"events":[{"title":"没写日历",
          "start":"2026-08-06T09:00:00+08:00","end":"2026-08-06T10:00:00+08:00",
          "direction":"past"}],"reminders":[]}
        """)

        let item = try #require(result.items.first)
        #expect(item.calendarName == "生活")
        #expect(item.needsConfirmation)
    }

    // MARK: - Direction consistency

    @Test("past pointing at a future time is flagged")
    func pastWithFutureTime() throws {
        let result = try Self.validate("""
        {"events":[{"title":"未来的回记","calendar":"工作",
          "start":"2026-08-20T09:00:00+08:00","end":"2026-08-20T10:00:00+08:00",
          "direction":"past"}],"reminders":[]}
        """)

        let item = try #require(result.items.first)
        #expect(item.needsConfirmation)
        #expect(item.confirmReason == "标记为回记但时间在未来")
    }

    @Test("future pointing at a past time is flagged")
    func futureWithPastTime() throws {
        let result = try Self.validate("""
        {"events":[],"reminders":[{"title":"过期的计划","calendar":"工作",
          "due":"2026-07-01T09:00:00+08:00","direction":"future"}]}
        """)

        let item = try #require(result.items.first)
        #expect(item.needsConfirmation)
        #expect(item.confirmReason == "标记为规划但时间已过去")
    }

    @Test("A consistent direction is left alone")
    func consistentDirectionIsClean() throws {
        let result = try Self.validate("""
        {"events":[{"title":"已经开完的会","calendar":"工作",
          "start":"2026-08-06T09:00:00+08:00","end":"2026-08-06T10:00:00+08:00",
          "direction":"past"}],"reminders":[]}
        """)

        #expect(result.items.first?.needsConfirmation == false)
    }

    @Test("A missing direction is inferred from the item's own time")
    func directionInferredWhenAbsent() throws {
        let result = try Self.validate("""
        {"events":[
          {"title":"过去","calendar":"工作","start":"2026-08-01T09:00:00+08:00","end":"2026-08-01T10:00:00+08:00"},
          {"title":"未来","calendar":"工作","start":"2026-08-20T09:00:00+08:00","end":"2026-08-20T10:00:00+08:00"}
        ],"reminders":[]}
        """)

        #expect(result.items.count == 2)
        #expect(result.items[0].direction == .past)
        #expect(result.items[1].direction == .future)
        // Inference is a recovery, not a judgement call worth bothering the user
        // about, so it must not flag on its own.
        #expect(result.items.allSatisfy { !$0.needsConfirmation })
    }

    @Test("A garbage direction value falls back to inference rather than failing")
    func garbageDirectionRecovers() throws {
        let result = try Self.validate("""
        {"events":[{"title":"乱写方向","calendar":"工作",
          "start":"2026-08-01T09:00:00+08:00","end":"2026-08-01T10:00:00+08:00",
          "direction":"sideways"}],"reminders":[]}
        """)

        #expect(result.items.first?.direction == .past)
    }

    // MARK: - Time plausibility

    @Test("A time more than a year out is flagged")
    func implausiblyDistantTimeIsFlagged() throws {
        let result = try Self.validate("""
        {"events":[{"title":"很久以后","calendar":"工作",
          "start":"2029-01-01T09:00:00+08:00","end":"2029-01-01T10:00:00+08:00",
          "direction":"future"}],"reminders":[]}
        """)

        #expect(result.items.first?.confirmReason == "时间距今超过一年")
    }

    @Test("end before start is repaired to a one-hour event and flagged")
    func invertedRangeIsRepaired() throws {
        let result = try Self.validate("""
        {"events":[{"title":"时间反了","calendar":"工作",
          "start":"2026-08-06T15:00:00+08:00","end":"2026-08-06T09:00:00+08:00",
          "direction":"past"}],"reminders":[]}
        """)

        let item = try #require(result.items.first)
        let start = try #require(item.startDate)
        #expect(item.endDate == start.addingTimeInterval(3600))
        #expect(item.confirmReason?.contains("已修正") == true)
    }

    @Test("An event with a start but no end gets the default one-hour duration")
    func missingEndGetsDefaultDuration() throws {
        let result = try Self.validate("""
        {"events":[{"title":"没写结束","calendar":"工作",
          "start":"2026-08-06T09:00:00+08:00","direction":"past"}],"reminders":[]}
        """)

        let item = try #require(result.items.first)
        let start = try #require(item.startDate)
        #expect(item.endDate == start.addingTimeInterval(3600))
        // Filling in a conventional duration is not something to nag about.
        #expect(!item.needsConfirmation)
    }

    @Test("timeVague marks the card as needing confirmation")
    func vagueTimeIsFlagged() throws {
        let result = try Self.validate("""
        {"events":[{"title":"晚上写小说","calendar":"生活",
          "start":"2026-08-06T20:00:00+08:00","end":"2026-08-06T21:00:00+08:00",
          "direction":"future","timeVague":true}],"reminders":[]}
        """)

        let item = try #require(result.items.first)
        #expect(item.timeVague)
        #expect(item.confirmReason == "时间为推测")
    }

    // MARK: - Drops and unusable items

    @Test("An item with no title is dropped and recorded")
    func untitledItemIsDropped() throws {
        let result = try Self.validate("""
        {"events":[{"title":"   ","calendar":"工作",
          "start":"2026-08-06T09:00:00+08:00","direction":"past"}],
         "reminders":[{"calendar":"工作","direction":"future"}]}
        """)

        #expect(result.items.isEmpty)
        // Dropping silently would make the extraction look like it just missed
        // something; the log needs to be able to say what went where.
        #expect(result.dropped.count == 2)
    }

    @Test("An event with no start is kept but left unselected")
    func eventWithoutStartIsUnselected() throws {
        let result = try Self.validate("""
        {"events":[{"title":"缺时间","calendar":"工作","direction":"future"}],"reminders":[]}
        """)

        let item = try #require(result.items.first)
        #expect(item.startDate == nil)
        #expect(!item.isSelected)
        #expect(item.confirmReason?.contains("缺少时间") == true)
    }

    @Test("A reminder with no due date is valid and unflagged")
    func reminderWithoutDueIsFine() throws {
        let result = try Self.validate("""
        {"events":[],"reminders":[{"title":"有空再说","calendar":"生活","direction":"future"}]}
        """)

        let item = try #require(result.items.first)
        #expect(item.dueDate == nil)
        #expect(!item.needsConfirmation)
        #expect(item.isSelected)
    }

    // MARK: - Emoji normalisation

    @Test("Only a single emoji glyph survives normalisation", arguments: [
        ("📊", "📊"),
        ("", nil),
        ("  ", nil),
        ("会议", nil),      // model sent a word instead of an emoji
        ("📊📈", nil),      // more than one glyph
    ])
    func emojiIsNormalised(input: String, expected: String?) throws {
        let result = try Self.validate("""
        {"events":[{"title":"t","emoji":"\(input)","calendar":"工作",
          "start":"2026-08-06T09:00:00+08:00","direction":"past"}],"reminders":[]}
        """)

        #expect(result.items.first?.emoji == expected)
    }

    // MARK: - Flag precedence

    @Test("The first applicable reason is kept when a card breaks several rules")
    func firstReasonWins() throws {
        // Unknown calendar *and* a contradictory direction. The calendar problem
        // is checked first and is the more actionable of the two.
        let result = try Self.validate("""
        {"events":[{"title":"双重问题","calendar":"不存在的日历",
          "start":"2026-08-20T09:00:00+08:00","end":"2026-08-20T10:00:00+08:00",
          "direction":"past"}],"reminders":[]}
        """)

        #expect(result.items.first?.confirmReason?.contains("不存在的日历") == true)
    }
}
