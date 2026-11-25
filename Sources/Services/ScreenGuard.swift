import AppKit

/// Screen time walls (Settings › Screen time walls), both off until you turn them on:
/// - Time allowance: when you sit down at your Mac (open it, unlock it, come back after 5+ minutes), you get a set
///   number of minutes; then the decision wall asks what's next. A focus, work or study session counts as your
///   decision, and you get a fresh allowance when it ends.
/// - Away: if you were away for a while during your active hours, the away wall asks what happened before you can
///   carry on. Time covered by a closed task or event on your calendar, or a no-computer study session, doesn't count.
/// Test copies (-dataDir) leave it off unless they pass -guardTest.
@MainActor
final class ScreenGuard: ObservableObject {
    private unowned let model: AppModel
    private var timer: Timer?
    private var lastActive = Date()
    @Published private(set) var allowanceEnds: Date?

    init(model: AppModel) { self.model = model }

    private let d = UserDefaults.standard
    var allowanceOn: Bool { get { d.bool(forKey: "allowanceOn") } set { d.set(newValue, forKey: "allowanceOn"); restartAllowance() } }
    var allowanceMinutes: Int { get { d.object(forKey: "allowanceMinutes") as? Int ?? 30 } set { d.set(newValue, forKey: "allowanceMinutes"); restartAllowance() } }
    var awayOn: Bool { get { d.bool(forKey: "awayOn") } set { d.set(newValue, forKey: "awayOn") } }
    var awayMinutes: Int { get { d.object(forKey: "awayMinutes") as? Int ?? 20 } set { d.set(newValue, forKey: "awayMinutes") } }
    /// Active hours (minutes after midnight): away time outside them never counts.
    var activeFrom: Int { get { d.object(forKey: "activeFrom") as? Int ?? 8 * 60 } set { d.set(newValue, forKey: "activeFrom") } }
    var activeTo: Int { get { d.object(forKey: "activeTo") as? Int ?? 22 * 60 } set { d.set(newValue, forKey: "activeTo") } }

    private var isTest: Bool { LaunchOptions.has("-dataDir") && !LaunchOptions.has("-guardTest") }

    func start() {
        guard !isTest else { return }
        lastActive = Date()
        restartAllowance()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// A fresh allowance from now (sitting down, after a wall, after a session).
    func restartAllowance() {
        allowanceEnds = allowanceOn ? Date().addingTimeInterval(Double(allowanceMinutes * 60)) : nil
    }

    func extend(minutes: Int) { allowanceEnds = Date().addingTimeInterval(Double(minutes * 60)) }

    /// "I'm done": the display goes to sleep (which locks it, if your Mac asks for the password on wake).
    func stopForNow() {
        allowanceEnds = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }

    private func tick() {
        let now = Date()
        let engine = model.engine
        if engine.screenLocked || engine.displayAsleep { return }
        let idle = ScreenTimeTracker.idleSeconds
        // While a focus, work or study session runs, that's the decision made; a fresh allowance comes after.
        // A pause is a break: the allowance runs again, like a paused study session.
        let busy = (model.focus.running && !model.focus.isPaused) || (model.study.run.map { !$0.paused } ?? false)
        if busy, allowanceOn { allowanceEnds = now.addingTimeInterval(Double(allowanceMinutes * 60)) }

        guard idle < 30 else { return }   // not using it right now: nothing to decide
        let activeAt = now.addingTimeInterval(-idle)
        let gapStart = lastActive
        lastActive = max(lastActive, activeAt)
        let gap = activeAt.timeIntervalSince(gapStart)
        if gap >= 5 * 60 {
            // Back after a break: maybe the away wall, and a fresh allowance either way.
            // Only breaks that began during your active hours that day (not the first sit-down after a night).
            let began = gapStart.minutesSinceMidnight
            let duringDay = began >= activeFrom && began < activeTo && gapStart.isSameDay(activeAt)
            if awayOn, duringDay, !model.walls.isShowing, !busy, activeMinutes(gapStart, activeAt) >= awayMinutes, !excused(gapStart, activeAt) {
                model.walls.show(.away(from: gapStart, to: activeAt))
            }
            restartAllowance()
            return
        }
        if allowanceOn, !busy, !model.walls.isShowing, let ends = allowanceEnds, now >= ends {
            model.walls.show(.decision)
        }
    }

    /// Minutes of [a, b] that fall inside your active hours.
    func activeMinutes(_ a: Date, _ b: Date) -> Int {
        var total = 0.0
        var day = a.startOfDay
        while day < b {
            let s = max(a, day.addingTimeInterval(Double(activeFrom * 60)))
            let e = min(b, day.addingTimeInterval(Double(activeTo * 60)))
            if e > s { total += e.timeIntervalSince(s) }
            day = day.adding(days: 1)
        }
        return Int(total / 60)
    }

    /// Mostly covered by a closed task or event, or a no-computer study session: away for a reason.
    private func excused(_ a: Date, _ b: Date) -> Bool {
        var covered: [(Date, Date)] = []
        var day = a.startOfDay
        while day < b {
            for o in model.google.visibleOccurrences(on: day) where o.isBusy {
                if let s = o.start, let e = o.end { covered.append((s, e)) }
            }
            for e in model.google.visibleEvents(on: day) where !e.isAllDay { covered.append((e.start, e.end)) }
            day = day.adding(days: 1)
        }
        for l in model.store.studyLogs where l.mode == .offline { covered.append((l.startedAt, l.endedAt)) }
        // Merge and measure the overlap with [a, b].
        let parts = covered.compactMap { s, e -> (Date, Date)? in let x = max(s, a), y = min(e, b); return y > x ? (x, y) : nil }.sorted { $0.0 < $1.0 }
        var sum = 0.0, cur: (Date, Date)?
        for p in parts {
            if let c = cur, p.0 <= c.1 { cur = (c.0, max(c.1, p.1)) } else { if let c = cur { sum += c.1.timeIntervalSince(c.0) }; cur = p }
        }
        if let c = cur { sum += c.1.timeIntervalSince(c.0) }
        return sum >= 0.7 * b.timeIntervalSince(a)
    }
}
