import Foundation

/// Priority, hardness and how long things really take. Shared by the Mac and iPhone apps; the web has the same
/// rules in model.js (PRIORITIES, HARDNESS, typicalMinutes, parseMinutes).

enum Priority: String, CaseIterable, Identifiable, Comparable {
    case high, medium, low
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// For sorting: high first.
    var rank: Int { switch self { case .high: 0; case .medium: 1; case .low: 2 } }
    static func < (a: Priority, b: Priority) -> Bool { a.rank < b.rank }
    /// SF Symbol: one, two or three exclamation marks.
    var symbol: String { switch self { case .high: "exclamationmark.3"; case .medium: "exclamationmark.2"; case .low: "exclamationmark" } }
}

enum Hardness {
    static let range = 1...5
    static let titles = ["Easy", "Fairly easy", "Medium", "Hard", "Very hard"]
    static func title(_ n: Int) -> String { titles[min(5, max(1, n)) - 1] }
}

extension PlanTask {
    var priorityLevel: Priority? { priority.flatMap(Priority.init(rawValue:)) }
    var hardnessLevel: Int? { hardness.map { min(5, max(1, $0)) } }

    /// Every recorded time, shortest first.
    var takenTimes: [Int] { (timeTaken ?? [:]).values.filter { $0 > 0 }.sorted() }

    /// Every recorded time, latest first: by when it was checked off (or, without that, its day).
    var takenHistory: [Int] {
        let done = completions
        return (timeTaken ?? [:]).filter { $0.value > 0 }
            .map { (key: $0.key, minutes: $0.value, at: done[$0.key] ?? DateKey.date($0.key) ?? .distantPast) }
            .sorted { $0.at != $1.at ? $0.at > $1.at : Self.bonusKeyOrder($1.key, $0.key) }
            .map(\.minutes)
    }

    /// How long it takes: the average of your recorded times, weighted toward the latest like momentum (the
    /// latest counts 1, the one before 0.95, then 0.95², …), so it follows you as you get faster or slower.
    /// nil until it has been timed once.
    var typicalMinutes: Int? { TaskStats.weightedAverage(takenHistory) }
}

enum TaskStats {
    /// How much each older time counts compared with the one after it.
    static let decay = 0.95

    /// Σ decayⁱ·xᵢ / Σ decayⁱ over values latest first (i = 0 for the latest), rounded to a whole minute.
    static func weightedAverage(_ latestFirst: [Int], decay: Double = decay) -> Int? {
        guard !latestFirst.isEmpty else { return nil }
        var sum = 0.0, weights = 0.0, w = 1.0
        for x in latestFirst { sum += w * Double(x); weights += w; w *= decay }
        return Int((sum / weights).rounded())
    }

    /// "45", "45m", "1:30", "1h 30m", "1.5h", "90 min" → minutes. nil if it isn't a length.
    static func parseMinutes(_ text: String) -> Int? {
        let s = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let colon = s.firstIndex(of: ":") {
            guard let h = Int(s[..<colon]), let m = Int(s[s.index(after: colon)...]), h >= 0, (0..<60).contains(m) else { return nil }
            return positive(h * 60 + m)
        }
        var total = 0.0, number = "", found = false
        func flush(_ unit: Character?) -> Bool {
            guard !number.isEmpty else { return unit == nil }
            guard let v = Double(number) else { return false }
            total += unit == "h" ? v * 60 : v
            number = ""; found = true
            return true
        }
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c.isNumber || c == "." { number.append(c) }
            else if c == "h" { guard flush("h") else { return nil }; i = skipLetters(s, from: i); continue }
            else if c == "m" { guard flush("m") else { return nil }; i = skipLetters(s, from: i); continue }
            else if c != " " { return nil }
            i = s.index(after: i)
        }
        guard flush(nil), found else { return nil }
        return positive(Int(total.rounded()))
    }

    private static func skipLetters(_ s: String, from i: String.Index) -> String.Index {
        var j = i
        while j < s.endIndex, s[j].isLetter { j = s.index(after: j) }
        return j
    }

    private static func positive(_ n: Int) -> Int? { n > 0 && n < 24 * 60 ? n : nil }

    /// 45 → "45 min", 90 → "1 hr 30 min", 120 → "2 hr".
    static func format(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(minutes % 60) min"
    }
}

extension Store {
    /// Writes down (or clears, with nil) how long one occurrence took.
    func setTimeTaken(_ occ: Occurrence, minutes: Int?) {
        guard let i = tasks.firstIndex(where: { $0.id == occ.task.id }) else { return }
        var times = tasks[i].timeTaken ?? [:]
        times[occ.key] = minutes.flatMap { $0 > 0 ? $0 : nil }
        tasks[i].timeTaken = times.isEmpty ? nil : times
    }
}
