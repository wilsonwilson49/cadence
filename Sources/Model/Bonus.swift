import Foundation

/// Bonus tasks (kind "bonus"): optional extras. They're listed (Today's "Bonus" section, Focus) but never required:
/// no date to miss, no reminders, not in today's progress, never overdue. Each one finished during a focus session
/// is worth extra points. Same rules on the web (model.js).
///
/// They come around in rounds, and each round can be checked off up to a limit (`bonusLimit`: once by default, a
/// number, or no limit). A second check-off on the same day is kept under "yyyy-MM-dd#2", and so on.
/// - Just once: one round, from its start date on.
/// - On a schedule (every day, week, month, year; the same repeat rules as habits and events): a new round on each
///   repeat day, which lasts until the next one. Unused check-offs don't carry over.
/// - After it's done, with a break (like a task's): once a round's check-offs are used up, it takes `cycleGapDays`
///   off, then comes back, `cycleTimes` rounds in all. Needs a limit (with no limit a round is never used up).
enum Bonus {
    /// Points for each bonus task finished during a focus session (before the focus multiplier).
    static let points = 15
    /// The limits offered in the editor (0 = no limit).
    static let limitChoices = [1, 2, 3, 5, 10, 0]
    static func limitLabel(_ n: Int) -> String { n <= 0 ? "No limit" : n == 1 ? "Once" : "\(n) times" }
}

extension PlanTask {
    var isBonus: Bool { kind == "bonus" }

    /// How many times each round can be checked off; nil = no limit.
    var bonusMax: Int? {
        guard let l = bonusLimit else { return 1 }
        return l <= 0 ? nil : l
    }
    /// "After it's done, with a break" (a bonus task's; tasks keep theirs as an until-done cycle).
    var isBonusCycle: Bool { isBonus && cycleGapDays != nil && bonusMax != nil }
    var isBonusRepeating: Bool { isBonus && !isBonusCycle && recurrence.isRepeating }
    /// Check-offs ever made.
    var bonusCount: Int { completions.count }

    // MARK: Rounds

    /// The round `day` falls in: from its start, to the day after it ends (nil = open-ended). nil when there's no
    /// round then: before it starts, during a break, or after the last one.
    func bonusRound(on day: Date) -> (start: Date, end: Date?)? {
        guard isBonus else { return nil }
        let d = day.startOfDay
        if isBonusCycle {
            return bonusCycleRounds().first { d >= $0.start && ($0.end.map { d < $0 } ?? true) }.map { ($0.start, $0.end) }
        }
        if recurrence.isRepeating {
            guard let s = repStart(on: d) else { return nil }
            var end = nextBonusRepeat(after: s)
            if end == nil {
                // The last one: it lasts one repeat (a day, a week…), and never past an end date.
                let unit: Calendar.Component = [.daily: .day, .weekly: .weekOfYear, .monthly: .month, .yearly: .year][recurrence.frequency] ?? .day
                end = Calendar.current.date(byAdding: unit, value: max(1, recurrence.interval), to: s)
                if case .onDate(let e) = recurrence.end { end = min(end ?? e.startOfDay.adding(days: 1), e.startOfDay.adding(days: 1)) }
            }
            if let end, d >= end { return nil }
            return (s, end)
        }
        let s = startDate.startOfDay
        return d >= s ? (s, nil) : nil
    }

    /// A cycle's rounds so far: each finished one (start, the day after its last check-off), then the open or
    /// upcoming one (end nil), unless all of them are done.
    func bonusCycleRounds() -> [(start: Date, end: Date?)] {
        guard let max = bonusMax else { return [(startDate.startOfDay, nil)] }
        let keys = completions.keys.sorted(by: Self.bonusKeyOrder)
        var out: [(start: Date, end: Date?)] = []
        var start = startDate.startOfDay
        for _ in 0..<Swift.max(1, cycleTimes ?? 1) {
            let from = DateKey.string(start)
            let inRound = keys.filter { $0.prefix(10) >= from }
            guard inRound.count >= max, let last = DateKey.date(inRound[max - 1]) else { out.append((start, nil)); break }
            out.append((start, last.adding(days: 1)))
            start = last.adding(days: Swift.max(0, cycleGapDays ?? 0))
        }
        return out
    }

    /// The first repeat day after `day` (within about a year).
    private func nextBonusRepeat(after day: Date) -> Date? {
        var c = day.startOfDay.adding(days: 1)
        for _ in 0..<400 {
            if occursByPattern(c) { return c }
            c = c.adding(days: 1)
        }
        return nil
    }

    /// When the next round starts, if it isn't on now (or it's used up): for "back on Tue".
    func bonusNextRound(after day: Date) -> Date? {
        let d = day.startOfDay
        if isBonusCycle { return bonusCycleRounds().first { $0.start > d }?.start }
        if recurrence.isRepeating { return nextBonusRepeat(after: d) }
        return startDate.startOfDay > d ? startDate.startOfDay : nil
    }

    /// The check-offs in the round `day` falls in.
    func bonusRoundKeys(on day: Date) -> [String] {
        guard let r = bonusRound(on: day) else { return [] }
        let from = DateKey.string(r.start), to = r.end.map(DateKey.string)
        return completions.keys.filter { k in k.prefix(10) >= from && (to.map { k.prefix(10) < $0 } ?? true) }.sorted(by: Self.bonusKeyOrder)
    }

    /// Check-offs left in the round on `day`; nil = no limit. 0 when there's no round then.
    func bonusLeft(on day: Date) -> Int? {
        guard bonusRound(on: day) != nil else { return 0 }
        return bonusMax.map { Swift.max(0, $0 - bonusRoundKeys(on: day).count) }
    }
    var bonusLeft: Int? { bonusLeft(on: Date()) }

    /// Nothing more to check off on `day` (used up, on a break, or not started). Never true for anything else.
    func bonusUsedUp(on day: Date) -> Bool { isBonus && bonusLeft(on: day) == 0 }
    var bonusUsedUp: Bool { bonusUsedUp(on: Date()) }

    // MARK: Check-off keys

    /// The check-offs made on `day`, in order ("yyyy-MM-dd", "yyyy-MM-dd#2", …).
    func bonusKeys(on day: Date) -> [String] {
        let base = DateKey.string(day)
        return completions.keys.filter { $0 == base || $0.hasPrefix(base + "#") }.sorted(by: Self.bonusKeyOrder)
    }

    /// The key the next check-off on `day` goes under.
    func nextBonusKey(on day: Date) -> String {
        let base = DateKey.string(day)
        if completions[base] == nil { return base }
        var n = 2
        while completions["\(base)#\(n)"] != nil { n += 1 }
        return "\(base)#\(n)"
    }

    /// For its row: the next free check-off, or once it's used up, the last one made that day (so it shows ticked).
    func bonusKey(on day: Date) -> String {
        if bonusUsedUp(on: day), let last = bonusKeys(on: day).last { return last }
        return nextBonusKey(on: day)
    }

    /// On the bonus list that day: during a round, while it can still be checked off (or it was used up that day).
    func bonusListed(on day: Date) -> Bool {
        isBonus && archived != true && bonusRound(on: day) != nil && (!bonusUsedUp(on: day) || !bonusKeys(on: day).isEmpty)
    }

    // MARK: Words

    /// This round: "Once", "Done", "2 of 3 done", "Done 5 times · no limit".
    func bonusSummary(on day: Date = Date()) -> String {
        let n = bonusRoundKeys(on: day).count
        guard let max = bonusMax else { return n == 0 ? "No limit" : "Done \(n) time\(n == 1 ? "" : "s") · no limit" }
        if max == 1 { return n == 0 ? "Once" : "Done" }
        return n == 0 ? "Up to \(max) times" : "\(Swift.min(n, max)) of \(max) done"
    }
    var bonusSummary: String { bonusSummary() }

    /// How it comes back, or nil if it doesn't: "Every day", "Back 3 days after it's done · round 2 of 5".
    var bonusRepeatSummary: String? {
        if isBonusCycle, let gap = cycleGapDays {
            let rounds = bonusCycleRounds(), times = Swift.max(1, cycleTimes ?? 1)
            let g = gap > 0 && gap % 7 == 0 ? "\(gap / 7) week\(gap == 7 ? "" : "s")" : "\(gap) day\(gap == 1 ? "" : "s")"
            if rounds.count >= times, rounds.last?.end != nil { return "All \(times) rounds done" }
            return "Back \(g) after it's done · round \(rounds.count) of \(times)"
        }
        if recurrence.isRepeating {
            return recurrence.summary(start: startDate) + (bonusMax == 1 ? "" : ", each time")
        }
        return nil
    }

    /// Finished for good: a once-only one used up, a cycle's last round done, or a schedule that has ended.
    var bonusFinished: Bool {
        let today = Date().startOfDay
        guard bonusRound(on: today) == nil || bonusUsedUp(on: today) else { return false }
        return bonusNextRound(after: today) == nil && today >= startDate.startOfDay
    }

    static func bonusKeyOrder(_ a: String, _ b: String) -> Bool {
        let (da, db) = (a.prefix(10), b.prefix(10))
        if da != db { return da < db }
        return bonusIndex(a) < bonusIndex(b)
    }

    private static func bonusIndex(_ key: String) -> Int {
        key.split(separator: "#", maxSplits: 1).dropFirst().first.flatMap { Int($0) } ?? 1
    }
}

extension Store {
    /// Bonus tasks to show on `day` (today): highest priority first, then oldest first.
    func bonusTasks(on day: Date = Date()) -> [Occurrence] {
        let d = day.startOfDay
        return tasks.filter { $0.bonusListed(on: d) }
            .sorted { ($0.priorityLevel?.rank ?? 3, $0.createdAt) < ($1.priorityLevel?.rank ?? 3, $1.createdAt) }
            .map { Occurrence(task: $0, day: d) }
    }

    /// Bonus tasks that can still be checked off today.
    func openBonusTasks(on day: Date = Date()) -> [Occurrence] { bonusTasks(on: day).filter { !$0.isDone } }

    /// Takes back the last check-off of a bonus task on `day` (its reflection stays, like unchecking anything).
    func undoBonus(_ taskID: UUID, on day: Date = Date()) {
        guard let t = task(taskID), let key = t.bonusKeys(on: day).last else { return }
        uncomplete(Occurrence(task: t, day: day.startOfDay, fixedKey: key))
    }
}
