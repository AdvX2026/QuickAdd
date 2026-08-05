import Foundation
import Testing

@testable import QuickAdd

/// Decoding is the other place PRD §14 requires tests. `json_object` mode only
/// guarantees the document parses — every field beyond that is the model's word,
/// so decoding has to survive anything that is syntactically JSON.
struct ExtractionSchemaTests {

    static func decode(_ json: String) throws -> ExtractionResponse {
        try JSONDecoder().decode(ExtractionResponse.self, from: Data(json.utf8))
    }

    @Test("A well-formed response decodes every field")
    func fullResponseDecodes() throws {
        let r = try Self.decode("""
        {
          "events":[{"title":"过 Q3 方案","emoji":"📊","details":"与张三",
            "calendar":"工作","start":"2026-08-06T10:00:00+08:00",
            "end":"2026-08-06T11:30:00+08:00","allDay":false,
            "direction":"past","timeVague":false}],
          "reminders":[{"title":"交周报","emoji":"📝","details":"",
            "calendar":"工作","due":"2026-08-07T23:59:00+08:00",
            "direction":"future","timeVague":false}],
          "recap_range":{"start":"2026-08-06T00:00:00+08:00","end":"2026-08-06T23:59:00+08:00"}
        }
        """)

        #expect(r.events.count == 1)
        #expect(r.reminders.count == 1)
        #expect(r.events[0].title == "过 Q3 方案")
        #expect(r.events[0].allDay == false)
        #expect(r.recapRange?.start == "2026-08-06T00:00:00+08:00")
    }

    @Test("Missing top-level arrays decode as empty rather than throwing")
    func missingArraysDecodeEmpty() throws {
        let r = try Self.decode(#"{"recap_range":null}"#)
        #expect(r.events.isEmpty)
        #expect(r.reminders.isEmpty)
        #expect(r.recapRange == nil)
    }

    @Test("An empty object decodes")
    func emptyObjectDecodes() throws {
        let r = try Self.decode("{}")
        #expect(r.events.isEmpty)
    }

    @Test("A malformed element is skipped without losing its neighbours")
    func badElementDoesNotSinkTheArray() throws {
        // The middle element is a string where an object belongs. Array's
        // synthesised decoding would discard all three.
        let r = try Self.decode("""
        {"events":[
          {"title":"第一条","calendar":"工作"},
          "垃圾数据",
          {"title":"第三条","calendar":"生活"}
        ],"reminders":[]}
        """)

        #expect(r.events.count == 2)
        #expect(r.events[0].title == "第一条")
        #expect(r.events[1].title == "第三条")
    }

    @Test("A field of the wrong type does not fail the document")
    func wrongTypedFieldIsTolerated() throws {
        // allDay as a string rather than a bool.
        let r = try Self.decode("""
        {"events":[{"title":"ok","calendar":"工作","allDay":"yes"},
                   {"title":"也 ok","calendar":"工作","allDay":true}],"reminders":[]}
        """)

        #expect(r.events.count == 1)
        #expect(r.events[0].title == "也 ok")
    }

    @Test("Unknown extra fields are ignored")
    func unknownFieldsIgnored() throws {
        let r = try Self.decode("""
        {"events":[{"title":"t","calendar":"工作","确信度":0.9}],
         "reminders":[],"clarifications":[],"未来字段":"x"}
        """)

        #expect(r.events.count == 1)
    }
}

struct ISO8601ParsingTests {

    @Test("Offset form parses")
    func offsetForm() throws {
        let d = try #require(ISO8601.parse("2026-08-06T10:00:00+08:00"))
        #expect(ISO8601.string(from: d, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
                == "2026-08-06T10:00:00+08:00")
    }

    @Test("Zulu form parses")
    func zuluForm() throws {
        let d = try #require(ISO8601.parse("2026-08-06T02:00:00Z"))
        #expect(ISO8601.string(from: d, timeZone: TimeZone(identifier: "Asia/Shanghai")!)
                == "2026-08-06T10:00:00+08:00")
    }

    @Test("Fractional seconds parse")
    func fractionalSeconds() throws {
        #expect(ISO8601.parse("2026-08-06T10:00:00.500+08:00") != nil)
    }

    @Test("An offset-less timestamp falls back to the device timezone")
    func naiveFallback() throws {
        // The prompt forbids this, but a prompt rule is not an enforcement
        // mechanism — dropping the time entirely would be worse than assuming
        // the user's own timezone.
        #expect(ISO8601.parse("2026-08-06T10:00:00") != nil)
    }

    @Test("Empty and null-ish values parse as nil", arguments: [
        "", "   ", "null", "NULL",
    ])
    func emptyIsNil(input: String) {
        #expect(ISO8601.parse(input) == nil)
    }

    @Test("nil parses as nil")
    func nilIsNil() {
        #expect(ISO8601.parse(nil) == nil)
    }

    @Test("Unparseable text yields nil rather than a wrong date")
    func garbageIsNil() {
        #expect(ISO8601.parse("下周一早上") == nil)
        #expect(ISO8601.parse("2026年8月6日") == nil)
    }
}
