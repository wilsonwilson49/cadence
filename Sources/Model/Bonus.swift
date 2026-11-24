import Foundation

/// Bonus tasks (kind "bonus"): optional extras. They're listed (Today's "Bonus" section, Focus) but never required:
/// no date to miss, no reminders, not in today's progress, never overdue. Each one finished during a focus session
/// is worth extra points. They can be checked off a set number of times in all (once by default, or with no limit);
/// a second check-off on the same day is kept under "yyyy-MM-dd#2", and so on. Same rules on the web (model.js).
enum Bonus {
    /// Points for each bonus task finished during a focus session (before the focus multiplier).
    static let points = 15
    /// The limits offered in the editor (0 = no limit).
    static let limitChoices = [1, 2, 3, 5, 10, 0]
    static func limitLabel(_ n: Int) -> String { n <= 0 ? "No limit" : n == 1 ? "Once" : "\(n) times" }
}

extension PlanTask {
    var isBonus: Bool { kind == "bonus" }

    /// How many times it can be checked off in all; nil = no limit.
    var bonusMax: Int? {
        guard let l = bonusLimit else { return 1 }
        return l <= 0 ? nil : l
    }
    var bonusCount: Int { completions.count }
    /// Check-offs left; nil = no limit.
    var bonusLeft: Int? { bonusMax.map { max(0, $0 - bonusCount) } }
    /// A bonus task checked off as many times as it can be (never true for anything else).
    var bonusUsedUp: Bool { isBonus && bonusLeft == 0 }

    /// The check-offs made on `day`, in order ("yyyy-MM-dd", "yyyy-MM-dd#2", …).
    func bonusKeys(on day: Date) -> [String] {
        let base = DateKey.string(day)
        return completions.keys.filter { $0 == base || $0.hasPrefix(base + "#") }.sorted { bonusIndex($0) < bonusIndex($1) }
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
        if bonusUsedUp, let last = bonusKeys(on: day).last { return last }
        return nextBonusKey(on: day)
    }

    /// On the bonus list that day: from its start date, while it can still be checked off (or it was used up that day).
    func bonusListed(on day: Date) -> Bool {
        isBonus && archived != true && day.startOfDay >= startDate.startOfDay && (!bonusUsedUp || !bonusKeys(on: day).isEmpty)
    }

    /// "Once", "2 of 3 done", "done 5 times · no limit".
    var bonusSummary: String {
        let n = bonusCount
        guard let max = bonusMax else { return n == 0 ? "As often as you like" : "Done \(n) time\(n == 1 ? "" : "s") · no limit" }
        if max == 1 { return n == 0 ? "Once" : "Done" }
        return n == 0 ? "Up to \(max) times" : "\(min(n, max)) of \(max) done"
    }

    private func bonusIndex(_ key: String) -> Int {
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
