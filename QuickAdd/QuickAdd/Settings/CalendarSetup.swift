import Foundation

/// The calendar layout this app is set up for, and the definitions that teach
/// the model what belongs in each one.
///
/// The text below is the version validated in `Spike/deepseek-probe.swift`
/// (9/9 agreement across runs). Seeding it here instead of asking for it to be
/// typed into eight text fields on device is deliberate, and so is the fact
/// that these are one specific person's calendar names — see `notice.md` in
/// this directory before changing either.
enum CalendarSetup {

    /// Where anything unclassifiable goes. Preferred as the default when a
    /// calendar by this title exists.
    static let defaultEventCalendarTitle = "日历"

    /// Title → definition. A title that is absent simply gets no seed, which is
    /// why reminder lists can pass an empty table.
    ///
    /// Every definition carries a decidable test rather than only examples.
    /// Examples alone failed: 工作 listed three of them and anything outside
    /// those three got pulled into 创意, whose definition opened with
    /// "任何创意类".
    static let eventDefinitions: [String: String] = [
        "工作": "本职工作相关的一切——开会、写合同、甲方对接、做方案、汇报。"
              + "判断标准是「有他人或组织在等这件事的结果」。"
              + "不包括自发的个人项目（那属于 创意）、出差的行程本身（那属于 旅行）；"
              + "出差期间的会议和工作内容仍属于 工作。",

        "创意": "为自己而做的创作——写作、绘画、设计、个人项目、灵感记录。"
              + "判断标准是「在产出作品，且没有外部交付对象」。"
              + "不包括工作要求的产出（那属于 工作）、以吸收为主的学习（那属于 学习）。",

        "学习": "以吸收知识为目的的活动——上课、读书、看教程、备考、练习技能。"
              + "判断标准是「主要在输入，不产出作品」。"
              + "不包括为工作交付而做的调研（那属于 工作）、以创作为目的的动手（那属于 创意）。",

        "个人": "与自己身体和事务有关、需要去办的事——就医体检、健身、理财、证件办理、理发。"
              + "判断标准是「有明确事项要完成，且只涉及自己」。"
              + "不包括纯粹放松的活动（那属于 生活）、系统性的学习（那属于 学习）。",

        "生活": "日常起居与社交放松——吃饭、聚会、看电影、逛街、家务、散步。"
              + "判断标准是「以放松或维持日常为目的，没有明确产出」。"
              + "不包括需要办理的个人事务（那属于 个人）、离开常住地的出行（那属于 旅行）。",

        "旅行": "离开常住地的出行——行程、交通、住宿、景点，出差的行程部分也算。"
              + "判断标准是「涉及跨城市或过夜的出行」。"
              + "不包括本地的日常外出（那属于 生活）、出差期间的具体工作（那属于 工作）。",

        "睡眠": "睡觉、午睡、作息记录。",

        "日历": "默认归类。以上都不合适、或拿不准时放这里。",
    ]

    // MARK: - Ambiguity
    //
    // A calendar title is unique only within an account. Two accounts can each
    // hold a 工作, and the model names calendars by title, so a duplicated title
    // has no correct resolution — resolving it either way writes into an account
    // the user never chose, which is how a personal recap ends up on a
    // colleague-visible work calendar.
    //
    // Rather than guess, a duplicated title stops existing for the pipeline: it
    // is not offered to the model and not resolvable. Settings is where the user
    // breaks the tie, by leaving exactly one of them enabled.

    /// Titles that more than one *enabled* calendar answers to.
    static func ambiguousTitles(among configs: [CalendarConfig]) -> Set<String> {
        let grouped = Dictionary(grouping: configs.filter(\.isEnabled), by: \.title)
        return Set(grouped.lazy.filter { $0.value.count > 1 }.map(\.key))
    }

    /// Enabled and unambiguous — the only calendars the prompt and the validator
    /// are allowed to see.
    static func usable(_ configs: [CalendarConfig]) -> [CalendarConfig] {
        let ambiguous = ambiguousTitles(among: configs)
        return configs.filter { $0.isEnabled && !ambiguous.contains($0.title) }
    }

    // MARK: - Merge

    /// Rebuilds the stored configs from what EventKit currently reports.
    ///
    /// A definition the user wrote is never overwritten — a seed only ever
    /// fills a blank. Titles are refreshed so a rename in Calendar.app does not
    /// strand the definition attached to that calendar.
    static func merge(
        discovered: [(identifier: String, title: String, sourceTitle: String)],
        into existing: [CalendarConfig],
        seeds: [String: String]
    ) -> [CalendarConfig] {
        let byIdentifier = Dictionary(
            existing.map { ($0.calendarIdentifier, $0) },
            uniquingKeysWith: { first, _ in first })

        // A calendar that arrives sharing a title with another starts disabled,
        // so a second account syncing in can never quietly join the pool the
        // model picks from. Calendars already in `existing` keep whatever the
        // user set — the tie may well be one they already broke.
        let collidingTitles = Set(
            Dictionary(grouping: discovered, by: \.title)
                .lazy.filter { $0.value.count > 1 }.map(\.key))

        return discovered.map { calendar in
            var config = byIdentifier[calendar.identifier]
                ?? CalendarConfig(calendarIdentifier: calendar.identifier,
                                  title: calendar.title,
                                  isEnabled: !collidingTitles.contains(calendar.title))
            config.title = calendar.title
            config.sourceTitle = calendar.sourceTitle

            let written = config.definition.trimmingCharacters(in: .whitespacesAndNewlines)
            if written.isEmpty, let seed = seeds[calendar.title] {
                config.definition = seed
            }
            return config
        }
    }

    /// Keeps the user's pick while it still exists, otherwise prefers
    /// `preferred` and falls back to whatever is enabled.
    ///
    /// `AppSettings.isConfigured` requires a non-empty default, and a wrong one
    /// silently routes every unclassifiable item into an arbitrary calendar, so
    /// this must not just grab the first entry EventKit happens to return.
    static func resolveDefault(
        current: String,
        among configs: [CalendarConfig],
        preferring preferred: String?
    ) -> String {
        // Candidates are the usable set, so the fallback can never be a title
        // that resolves to two different calendars.
        let candidates = usable(configs)
        if candidates.contains(where: { $0.title == current }) { return current }
        if let preferred, candidates.contains(where: { $0.title == preferred }) { return preferred }
        return candidates.first?.title ?? ""
    }
}
