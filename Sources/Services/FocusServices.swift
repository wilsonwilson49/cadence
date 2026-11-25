import AppKit
import SwiftUI

/// Screen time, measured on this Mac: which app is in front while you're actually using the computer (not
/// idle, locked or asleep). Opt-in. Each day becomes one ScreenDay record that syncs, so the web shows it too.
/// Nothing leaves the Mac except those daily per-app totals.
@MainActor
final class ScreenTimeTracker: ObservableObject {
    /// Test runs (launched with -dataDir) keep their own preferences, so they never switch tracking on for you.
    private static let defaults: UserDefaults = LaunchOptions.has("-dataDir")
        ? (UserDefaults(suiteName: "com.ryanpark.cadence.debug") ?? .standard) : .standard
    private unowned let model: AppModel
    private var timer: Timer?
    private var lastSample = Date()
    private var lastWrite = Date.distantPast
    private var nudged: Set<String> = []

    /// This Mac's totals for today (seconds per app), live.
    @Published private(set) var today: [String: Int] = [:]
    @Published private(set) var frontmostApp: String?
    @Published var enabled: Bool {
        didSet { Self.defaults.set(enabled, forKey: "trackScreenTime"); if enabled { start() } else { flush(); stop() } }
    }

    private let deviceID: String = {
        if let id = ScreenTimeTracker.defaults.string(forKey: "screenDeviceID") { return id }
        let id = UUID().uuidString
        ScreenTimeTracker.defaults.set(id, forKey: "screenDeviceID")
        return id
    }()
    private var dayKey = DateKey.string(Date())
    private var recordID: String { "\(dayKey)|\(deviceID)".uppercased() }

    init(model: AppModel) {
        self.model = model
        enabled = Self.defaults.bool(forKey: "trackScreenTime")
    }

    func start() {
        frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName
        // Pick up today's totals saved earlier (after a relaunch).
        if let saved = model.store.screenDays.first(where: { $0.id == recordID }) {
            today = Dictionary(saved.apps.map { ($0.name, $0.seconds) }, uniquingKeysWith: +)
        }
        guard enabled, timer == nil else { return }
        lastSample = Date()
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stop() { timer?.invalidate(); timer = nil }

    /// Seconds since the last keyboard/mouse/trackpad input.
    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    var isUserActive: Bool {
        !model.engine.screenLocked && !model.engine.displayAsleep && Self.idleSeconds < 300
    }

    func isDistracting(_ app: String?) -> Bool {
        guard let app = app?.lowercased() else { return false }
        return model.store.settings.distractingApps.contains { app == $0.lowercased() || app.contains($0.lowercased()) }
    }

    var totalToday: Int { today.values.reduce(0, +) }
    var distractingToday: Int { today.filter { isDistracting($0.key) }.values.reduce(0, +) }

    private func sample() {
        let now = Date()
        let elapsed = min(60, Int(now.timeIntervalSince(lastSample).rounded()))
        lastSample = now
        frontmostApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let key = DateKey.string(now)
        if key != dayKey { flush(); dayKey = key; today = [:]; nudged = [] }
        guard isUserActive, let app = frontmostApp, elapsed > 0 else { return }
        today[app, default: 0] += elapsed
        checkLimits()
        if now.timeIntervalSince(lastWrite) > 300 { flush() }   // sync every 5 minutes, not every sample
    }

    /// Saves today's totals into the synced record.
    func flush() {
        guard !today.isEmpty else { return }
        lastWrite = Date()
        let apps = today.map { ScreenDay.App(name: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
        var day = ScreenDay(id: recordID, date: dayKey, device: Host.current().localizedName ?? "Mac", totalSeconds: totalToday, apps: apps)
        day.updatedAt = Date()
        if let i = model.store.screenDays.firstIndex(where: { $0.id == recordID }) { model.store.screenDays[i] = day }
        else { model.store.screenDays.append(day) }
        // Keep about two months of history.
        let cutoff = DateKey.string(Date().adding(days: -60))
        model.store.screenDays.removeAll { $0.date < cutoff }
    }

    private func checkLimits() {
        let s = model.store.settings
        if s.screenLimitMinutes > 0, totalToday > s.screenLimitMinutes * 60, nudged.insert("total").inserted {
            model.notifier.deliver(AlertContent(kind: .nudge, title: "Screen time: over your \(durationString(seconds: s.screenLimitMinutes * 60)) limit",
                                                body: "\(durationString(seconds: totalToday)) today. Maybe a good moment for a break, or a focus session.",
                                                symbol: "desktopcomputer", tint: .cyan), channels: s.nudgeChannels)
        }
        if s.distractingLimitMinutes > 0, distractingToday > s.distractingLimitMinutes * 60, nudged.insert("distracting").inserted {
            model.notifier.deliver(AlertContent(kind: .nudge, title: "Distracting apps: over your limit",
                                                body: "\(durationString(seconds: distractingToday)) in distracting apps today. Back to your list?",
                                                symbol: "exclamationmark.triangle", tint: .pink), channels: s.nudgeChannels)
        }
    }
}

/// Time-pressure focus sessions: pick what you'll get through, race the clock, score points.
/// Time in a distracting app (or with the Mac locked) counts against your focus percentage.
@MainActor
final class FocusEngine: ObservableObject {
    private unowned let model: AppModel
    private var timer: Timer?
    private var distractingStreak = 0
    private var lastNudge = Date.distantPast

    @Published private(set) var running = false
    @Published private(set) var startedAt = Date()
    @Published private(set) var endsAt = Date()
    @Published private(set) var minutes = 25
    @Published private(set) var picked: [String] = []
    @Published private(set) var finished: [String] = []
    @Published private(set) var awaySeconds = 0
    @Published private(set) var distractingSeconds = 0
    @Published private(set) var now = Date()
    @Published var result: FocusSession?
    private var sessionID = UUID()
    /// Bonus tasks ticked off on the Focus screen during this session (a task can appear more than once if it
    /// can be done more than once). Their reflections come when the session ends, like the list's.
    @Published private(set) var bonusTicks: [UUID] = []
    /// Bonus tasks checked off somewhere else (Today, the menu bar) while the session ran: "taskID|key".
    @Published private(set) var bonusCredited: [String] = []
    /// Paused (a break): when it began. The clock stops, nothing counts as away or distracted, and blocking lifts.
    @Published private(set) var pausedAt: Date?
    private var pausedSeconds = 0
    private var pauses: [FocusPause] = []
    private var lastPauseNudge = Date.distantPast
    var isPaused: Bool { running && pausedAt != nil }
    /// How long the current break has lasted.
    var pauseSeconds: Int { pausedAt.map { max(0, Int(now.timeIntervalSince($0))) } ?? 0 }
    /// The stretches of this session spent focusing so far (for the calendar).
    var liveSegments: [(start: Date, end: Date)] { FocusPause.segments(from: startedAt, to: pausedAt ?? now, pauses: pauses) }

    enum Mode: String { case sprint, work }
    /// Sprint: race the clock through a list. Work: one task, a clock counting up, until you complete it.
    @Published private(set) var mode: Mode = .sprint
    /// Work mode: the occurrence you're on ("taskID|yyyy-MM-dd").
    @Published private(set) var workID: String?
    /// Work mode blocks distracting apps and sites (Settings › Tough love) unless this is turned off.
    @Published var workBlocks = UserDefaults.standard.object(forKey: "workBlocks") as? Bool ?? true {
        didSet { UserDefaults.standard.set(workBlocks, forKey: "workBlocks") }
    }

    var isWorking: Bool { running && mode == .work }
    var workOccurrence: Occurrence? { workID.flatMap(occurrence) }
    /// Time spent so far, not counting pauses.
    var elapsedSeconds: Int { max(0, Int((pausedAt ?? now).timeIntervalSince(startedAt)) - pausedSeconds) }
    /// Share of the time so far not spent away or in distracting apps.
    var focusPercent: Int {
        let e = max(1, elapsedSeconds)
        return Int((100 * Double(e - min(e, awaySeconds + distractingSeconds)) / Double(e)).rounded())
    }

    init(model: AppModel) { self.model = model }

    var secondsLeft: Int { max(0, Int(endsAt.timeIntervalSince(pausedAt ?? now).rounded(.up))) }
    var pauseClock: String { String(format: "%d:%02d", pauseSeconds / 60, pauseSeconds % 60) }

    // MARK: Pause

    func pause() {
        guard running, pausedAt == nil else { return }
        let t = Date()
        pausedAt = t; now = t; distractingStreak = 0; lastPauseNudge = t
    }

    /// Back to it: the break is left out of the time, and a sprint gets its paused minutes back.
    func resume() {
        guard running, let p = pausedAt else { return }
        let t = Date(), d = t.timeIntervalSince(p)
        pausedSeconds += Int(d.rounded())
        endsAt = endsAt.addingTimeInterval(d)
        if d >= 1 { pauses.append(FocusPause(start: p, end: t)) }
        pausedAt = nil; now = t
    }

    func togglePause() { if isPaused { resume() } else { pause() } }
    var clock: String {
        if mode == .work {
            let s = elapsedSeconds
            return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
        }
        return String(format: "%d:%02d", secondsLeft / 60, secondsLeft % 60)
    }

    /// Work mode: latch onto one task. Switching from another logs the time spent on that one first.
    func startWork(_ occ: Occurrence) {
        if running { end(quiet: true) }
        result = nil
        workID = occ.id
        start(minutes: Focus.maxMinutes, picked: [occ.id], mode: .work)
    }

    /// Work mode's Complete: ends the session and opens the check-off, with the time already filled in.
    func completeWork() {
        guard isWorking, let id = workID else { return }
        let occ = workOccurrence
        let taken = max(1, Int((Double(elapsedSeconds) / 60).rounded()))
        finished = [id]
        end(quiet: true)
        // The reflection comes up right away, over everything, until it's written.
        if let occ { model.walls.reflect(on: [occ], minutes: taken) }
    }

    func start(minutes: Int, picked: [String], mode: Mode = .sprint) {
        self.mode = mode
        if mode == .sprint { workID = nil }
        self.minutes = minutes; self.picked = picked; finished = []
        bonusTicks = []; bonusCredited = []
        pausedAt = nil; pausedSeconds = 0; pauses = []
        awaySeconds = 0; distractingSeconds = 0; distractingStreak = 0
        startedAt = Date(); endsAt = startedAt.addingTimeInterval(Double(minutes * 60)); now = startedAt
        sessionID = UUID(); result = nil; running = true
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func toggleFinished(_ id: String) {
        if let i = finished.firstIndex(of: id) { finished.remove(at: i) } else { finished.append(id) }
        if !picked.isEmpty && finished.count == picked.count { end() }   // cleared the list: stop the clock
    }

    func addFiveMinutes() { endsAt = endsAt.addingTimeInterval(300); minutes += 5 }

    // MARK: Bonus tasks

    /// How many times this bonus task was done in this session so far.
    func bonusDone(_ id: UUID) -> Int {
        bonusTicks.filter { $0 == id }.count + bonusCredited.filter { $0.hasPrefix(id.uuidString + "|") }.count
    }

    /// Whether it can be ticked (again): not past its limit, counting this session's ticks.
    func canTickBonus(_ t: PlanTask) -> Bool {
        guard running, t.isBonus else { return false }
        guard let left = model.store.task(t.id)?.bonusLeft else { return true }
        return bonusTicks.filter { $0 == t.id }.count < left
    }

    func tickBonus(_ t: PlanTask) { if canTickBonus(t) { bonusTicks.append(t.id) } }

    func untickBonus(_ id: UUID) { if let i = bonusTicks.lastIndex(of: id) { bonusTicks.remove(at: i) } }

    /// A check-off happened (Store.onComplete): a bonus task done while a session runs counts for the session.
    func noteCompleted(_ t: PlanTask, key: String) {
        let id = "\(t.id.uuidString)|\(key)"
        guard running, t.isBonus, !bonusCredited.contains(id), !finished.contains(id) else { return }
        bonusCredited.append(id)
    }

    /// The ticked bonus tasks as check-offs to reflect on: each gets its own key ("…#2" for a second one today),
    /// and none goes past its task's limit.
    private func tickedBonusOccurrences() -> [Occurrence] {
        let today = Date().startOfDay
        var sim: [UUID: PlanTask] = [:]
        var out: [Occurrence] = []
        for id in bonusTicks {
            guard var t = sim[id] ?? model.store.task(id), t.isBonus, !t.bonusUsedUp else { continue }
            let key = t.nextBonusKey(on: today)
            out.append(Occurrence(task: model.store.task(id) ?? t, day: today, fixedKey: key))
            t.completions[key] = Date()   // only in this copy, to work out the next key
            sim[id] = t
        }
        return out
    }

    private func tick() {
        now = Date()
        if let p = pausedAt {
            // On a break: nothing counts. A reminder every 10 minutes, in case it's turned into something else.
            if now.timeIntervalSince(lastPauseNudge) >= 600 {
                lastPauseNudge = now
                let mins = Int(now.timeIntervalSince(p) / 60)
                model.notifier.deliver(AlertContent(kind: .nudge, title: "Still on a break?",
                    body: "Paused for \(mins) min\(mode == .work ? " from “\(workOccurrence?.task.title ?? "your task")”" : ""). Resume when you're back.",
                    symbol: "pause.circle", tint: .pink), channels: [.banner])
            }
            return
        }
        if now >= endsAt { end(); return }
        let engine = model.engine
        if engine.screenLocked || engine.displayAsleep { awaySeconds += 1; return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        if model.screenTime.isDistracting(app) {
            distractingSeconds += 1; distractingStreak += 1
            // A nudge after 20 seconds in a distracting app, at most once a minute.
            if distractingStreak >= 20 && now.timeIntervalSince(lastNudge) > 60 {
                lastNudge = now
                let title = mode == .work ? "Back to “\(workOccurrence?.task.title ?? "your task")”" : "Back to focus: \(clock) left"
                let body = mode == .work ? "\(clock) in. \(app ?? "This app") is on your distracting list."
                                         : "\(finished.count) of \(picked.count) done. \(app ?? "This app") is on your distracting list."
                model.notifier.deliver(AlertContent(kind: .nudge, title: title, body: body, symbol: "scope", tint: .pink), channels: [.banner])
            }
        } else {
            distractingStreak = 0
        }
    }

    /// Ends the session and logs it. `quiet`: you ended it yourself, so no "Time!" alert.
    func end(quiet: Bool = false) {
        guard running else { return }
        timer?.invalidate(); timer = nil
        running = false
        // Ended while paused: it ended when the break began.
        let end = min(pausedAt ?? Date(), endsAt)
        let elapsed = max(1, Int(end.timeIntervalSince(startedAt)) - pausedSeconds)
        let lost = min(elapsed, awaySeconds + distractingSeconds)
        let percent = Int((100 * Double(elapsed - lost) / Double(elapsed)).rounded())
        // Bonus tasks don't count toward clearing the list; each one finished is worth bonus points instead.
        let isBonus: (String) -> Bool = { [self] in occurrence($0)?.task.isBonus == true }
        let ticked = tickedBonusOccurrences()
        let extras = ticked.map(\.id) + bonusCredited
        let regularDone = finished.filter { !isBonus($0) }.count
        var s = FocusSession(id: sessionID, startedAt: startedAt, endedAt: end, plannedMinutes: minutes,
                             actualMinutes: Int((Double(elapsed) / 60).rounded()), picked: picked.count, finished: finished.count,
                             points: Focus.points(finished: regularDone, picked: picked.filter { !isBonus($0) }.count, focusPercent: percent,
                                                  bonus: extras.count + finished.filter(isBonus).count))
        s.finishedIds = finished
        s.finishedTitles = finished.compactMap { occurrence($0)?.task.title }
        if !extras.isEmpty {
            s.bonus = extras.count; s.bonusIds = extras
            s.bonusTitles = extras.compactMap { occurrence($0)?.task.title }
        }
        bonusTicks = []; bonusCredited = []
        s.awaySeconds = awaySeconds; s.distractingSeconds = distractingSeconds; s.focusPercent = percent
        if !pauses.isEmpty { s.pauses = pauses; s.pausedSeconds = pausedSeconds }
        pausedAt = nil
        if mode == .work {
            s.mode = "work"; s.occurrenceID = workID; s.title = workOccurrence?.task.title
            workID = nil
        }
        // Under a minute of work (picked by mistake, switched straight away) isn't worth a record.
        if mode == .work && elapsed < 60 && finished.isEmpty && extras.isEmpty { mode = .sprint; return }
        model.store.saveFocusSession(s)
        result = s
        if quiet { return }
        // Time's up: the reflections for what you finished come up right away, over everything, until they're written.
        let done = s.finishedIds.compactMap(occurrence) + ticked
        model.walls.reflect(on: done)
        model.notifier.deliver(AlertContent(kind: .nudge, title: "Time! \(s.finished) done\(s.bonusCount > 0 ? " + \(s.bonusCount) bonus" : "")",
                                            body: "\(percent)% focused · +\(s.points) points. Write your reflections to check them off.",
                                            symbol: "scope", tint: .pink), channels: model.store.settings.defaultChannels)
        model.screen = .focus
        model.windows.showMain()
    }

    /// "taskID|yyyy-MM-dd" → the occurrence. A bonus task's keeps its particular check-off ("…#2").
    func occurrence(_ id: String) -> Occurrence? {
        let parts = id.split(separator: "|").map(String.init)
        guard parts.count == 2, let uuid = UUID(uuidString: parts[0]), let t = model.store.task(uuid),
              let day = DateKey.date(parts[1]) else { return nil }
        return Occurrence(task: t, day: day, fixedKey: t.isBonus ? parts[1] : nil)
    }
}
