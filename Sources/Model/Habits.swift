import Foundation

// MARK: - Habits (Atomic Habits)

/// How a habit is meant to stick. Same JSON as the web app's `task.habit`.
struct HabitInfo: Codable, Hashable {
    /// "build" (a new habit), "stack" (after an existing one), "replace" (instead of a bad one), "break" (quit one).
    var style = "build"
    var identity: String?      // "I am someone who…"
    var cue: String?           // when and where
    var stackAfter: String?    // "After I…"
    var replaces: String?      // "Instead of…"
    var twoMinute: String?     // the 2-minute version
    var reward: String?
    var app: String?           // for a habit to break: the app to keep down (screen time)
    var limitMinutes: Int?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = c.value(.style, "build")
        identity = c.value(.identity, nil); cue = c.value(.cue, nil); stackAfter = c.value(.stackAfter, nil)
        replaces = c.value(.replaces, nil); twoMinute = c.value(.twoMinute, nil); reward = c.value(.reward, nil)
        app = c.value(.app, nil); limitMinutes = c.value(.limitMinutes, nil)
    }

    static let styles: [(id: String, label: String)] = [("build", "Build"), ("stack", "Stack on"), ("replace", "Replace"), ("break", "Break")]
    var styleLabel: String { ["build": "Building", "stack": "Stacked", "replace": "Replacing", "break": "Breaking"][style] ?? "Building" }
}

/// One line of the habit scorecard: something you already do, rated "+", "=" or "-".
struct ScoreItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var rating = "="
}

extension PlanTask {
    /// Habits are anything you repeat on a schedule (kept apart from one-off tasks): kind "habit", or any
    /// repeating non-event item, so older repeating tasks became habits. Same rule as isHabit() on the web.
    var isHabit: Bool { !isEvent && (kind == "habit" || recurrence.isRepeating) }

    /// "After I pour my coffee, I will meditate." and friends.
    var habitSentence: String? {
        let h = habit ?? HabitInfo()
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let lower = t.prefix(1).lowercased() + t.dropFirst()
        if h.style == "stack", let a = h.stackAfter, !a.isEmpty { return "After I \(a), I will \(lower)." }
        if h.style == "replace", let r = h.replaces, !r.isEmpty { return "Instead of \(r), I will \(lower)." }
        if h.style == "break" { return "I'm breaking the habit: \(lower)." }
        if let cue = h.cue, !cue.isEmpty { return "I will \(lower) \(cue)." }
        return nil
    }

    enum DayState: String { case done, missed, lapsed, open, off }

    struct HabitStats {
        var streak = 0, best = 0, votes = 0
        var rate: Int?
        var missTwice = false
        var grid: [(day: Date, state: DayState)] = []
        var today: DayState?
    }

    /// Streaks, rate and a 30-day grid. Same rules as habitStats() in the web app (model.js).
    func habitStats(today: Date = Date()) -> HabitStats {
        let t0 = today.startOfDay, start = startDate.startOfDay
        let done = Set(completions.keys), missedKeys = Set((missed ?? [:]).keys)
        func nextScheduled(after d: Date) -> Date? {
            var c = d.adding(days: 1)
            for _ in 0..<400 { if occursByPattern(c) { return c }; c = c.adding(days: 1) }
            return nil
        }
        func state(_ d: Date) -> DayState {
            let key = DateKey.string(d)
            if !isUntilDone { return done.contains(key) ? .done : missedKeys.contains(key) ? .missed : d.isSameDay(t0) ? .open : .lapsed }
            let next = nextScheduled(after: d)
            let until = next.map(DateKey.string) ?? "9999"
            if done.contains(where: { $0 >= key && $0 < until }) { return .done }
            if missedKeys.contains(where: { $0 >= key && $0 < until }) { return .missed }
            return next.map { $0 <= t0 } == true ? .lapsed : .open
        }
        var states: [(day: Date, state: DayState)] = []
        var c = t0.adding(days: -365)
        for _ in 0...365 {
            if c >= start && occursByPattern(c) { states.append((c, state(c))) }
            c = c.adding(days: 1)
        }
        var s = HabitStats()
        for (i, x) in states.enumerated().reversed() {
            if x.state == .open && i == states.count - 1 { continue }
            if x.state != .done { break }
            s.streak += 1
        }
        var run = 0
        for x in states { run = x.state == .done ? run + 1 : 0; s.best = max(s.best, run) }
        let recent = states.filter { $0.day > t0.adding(days: -30) && $0.state != .open }
        if !recent.isEmpty { s.rate = Int((100 * Double(recent.filter { $0.state == .done }.count) / Double(recent.count)).rounded()) }
        if let last = states.last(where: { $0.state != .open }) { s.missTwice = last.state != .done && states.contains { $0.state == .open } }
        s.votes = done.count
        s.grid = (0..<30).map { i in
            let d = t0.adding(days: i - 29)
            return (d, states.first { $0.day.isSameDay(d) }?.state ?? .off)
        }
        s.today = states.first { $0.day.isSameDay(t0) }?.state
        return s
    }
}

// MARK: - Focus sessions

/// A finished focus session. Same JSON as the web app's `focus` records.
struct FocusSession: Codable, Identifiable, Hashable {
    var id = UUID()
    var startedAt: Date
    var endedAt: Date
    var plannedMinutes: Int
    var actualMinutes: Int
    var picked: Int
    var finished: Int
    var finishedTitles: [String] = []
    var finishedIds: [String] = []
    var awaySeconds = 0
    var distractingSeconds = 0
    var focusPercent = 100
    var device = "mac"
    var points: Int
    var updatedAt: Date?

    init(id: UUID = UUID(), startedAt: Date, endedAt: Date, plannedMinutes: Int, actualMinutes: Int, picked: Int, finished: Int,
         points: Int) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt; self.plannedMinutes = plannedMinutes
        self.actualMinutes = actualMinutes; self.picked = picked; self.finished = finished; self.points = points
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); startedAt = c.value(.startedAt, Date()); endedAt = c.value(.endedAt, startedAt)
        plannedMinutes = c.value(.plannedMinutes, 25); actualMinutes = c.value(.actualMinutes, 0)
        picked = c.value(.picked, 0); finished = c.value(.finished, 0)
        finishedTitles = c.value(.finishedTitles, []); finishedIds = c.value(.finishedIds, [])
        awaySeconds = c.value(.awaySeconds, 0); distractingSeconds = c.value(.distractingSeconds, 0)
        focusPercent = c.value(.focusPercent, 100); device = c.value(.device, "web"); points = c.value(.points, 0)
        updatedAt = c.value(.updatedAt, nil)
    }
}

enum Focus {
    /// 10 points per task finished in time, ×1.5 at 90% focused (×1.25 at 75%), +20 for clearing the list.
    static func multiplier(_ percent: Int) -> Double { percent >= 90 ? 1.5 : percent >= 75 ? 1.25 : 1 }
    static func points(finished: Int, picked: Int, focusPercent: Int) -> Int {
        Int((Double(finished * 10) * multiplier(focusPercent)).rounded()) + (picked > 0 && finished >= picked ? 20 : 0)
    }
    static func levelStart(_ l: Int) -> Int { 50 * (l - 1) * l }
    static func level(points: Int) -> (level: Int, into: Int, span: Int) {
        var l = 1
        while levelStart(l + 1) <= points { l += 1 }
        return (l, points - levelStart(l), levelStart(l + 1) - levelStart(l))
    }
    static func streak(_ sessions: [FocusSession]) -> Int {
        let days = Set(sessions.map { DateKey.string($0.startedAt) })
        var d = Date().startOfDay
        if !days.contains(DateKey.string(d)) { d = d.adding(days: -1) }
        var n = 0
        while days.contains(DateKey.string(d)) { n += 1; d = d.adding(days: -1) }
        return n
    }
}

// MARK: - Screen time

/// One device's screen time for one day. id is "yyyy-MM-dd|DEVICE". Same JSON as the web's `screen` records.
struct ScreenDay: Codable, Identifiable, Hashable {
    struct App: Codable, Hashable { var name: String; var seconds: Int }
    var id: String
    var date: String
    var device: String
    var totalSeconds = 0
    var apps: [App] = []
    var updatedAt: Date?
}

func durationString(seconds: Int) -> String {
    let m = Int((Double(seconds) / 60).rounded()), h = m / 60
    return h > 0 ? "\(h)h \(m % 60)m" : "\(m)m"
}
