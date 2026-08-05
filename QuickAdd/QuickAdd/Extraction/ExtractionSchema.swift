import Foundation

/// Wire format for the extraction response (PRD §5.3).
///
/// Every field is optional and every array skips elements it cannot read. The
/// model guarantees valid JSON but not valid *structure* — `json_object` mode
/// constrains syntax only — so decoding must never throw on a well-formed
/// document with a bad field. Structural problems are the validator's job, and
/// it can only do that job if the response survives decoding.
struct ExtractionResponse: Decodable {
    var events: [RawItem] = []
    var reminders: [RawItem] = []
    var recapRange: RawRange?

    private enum CodingKeys: String, CodingKey {
        case events, reminders
        case recapRange = "recap_range"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = c.decodeLossyArray(RawItem.self, forKey: .events)
        reminders = c.decodeLossyArray(RawItem.self, forKey: .reminders)
        recapRange = try? c.decodeIfPresent(RawRange.self, forKey: .recapRange)
    }

    /// Shared shape for both kinds. Events carry `start`/`end`/`allDay`,
    /// reminders carry `due`; one type keeps the decoding tolerant rather than
    /// splitting on a discriminator the model might get wrong.
    struct RawItem: Decodable {
        var title: String?
        var emoji: String?
        var details: String?
        var calendar: String?
        var start: String?
        var end: String?
        var due: String?
        var allDay: Bool?
        var direction: String?
        var timeVague: Bool?
    }

    struct RawRange: Decodable {
        var start: String?
        var end: String?
    }
}

private extension KeyedDecodingContainer {
    /// Decodes an array, dropping elements that fail rather than failing whole.
    ///
    /// `Array`'s synthesised decoding is all-or-nothing: one malformed element
    /// discards every good one alongside it. Here a single bad card should cost
    /// the user that card, not the entire capture.
    func decodeLossyArray<T: Decodable>(_ type: T.Type, forKey key: Key) -> [T] {
        guard var unkeyed = try? nestedUnkeyedContainer(forKey: key) else { return [] }
        var result: [T] = []
        while !unkeyed.isAtEnd {
            if let element = try? unkeyed.decode(T.self) {
                result.append(element)
            } else {
                // Consume the slot so the cursor advances past the bad element.
                _ = try? unkeyed.decode(AnyDecodable.self)
            }
        }
        return result
    }
}

/// Placeholder used only to step over an element that failed to decode.
private struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {
        _ = try? decoder.singleValueContainer()
    }
}

// MARK: - Date parsing

enum ISO8601 {
    private static let withOffset: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Fallback for output that omits the offset despite the prompt requiring
    /// it. Interpreting it in the device timezone matches what the user meant.
    private static let naive: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = .current
        return f
    }()

    static func parse(_ string: String?) -> Date? {
        guard let s = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, s.lowercased() != "null"
        else { return nil }

        return withOffset.date(from: s)
            ?? withFractional.date(from: s)
            ?? naive.date(from: s)
    }

    static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }
}
