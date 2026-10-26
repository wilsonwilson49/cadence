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

    init(model: AppModel) { self.model = model }

    var secondsLeft: Int { max(0, Int(endsAt.timeIntervalSince(now).rounded(.up))) }
    var clock: String { String(format: "%d:%02d", secondsLeft / 60, secondsLeft % 60) }

    func start(minutes: Int, picked: [String]) {
        self.minutes = minutes; self.picked = picked; finished = []
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

    private func tick() {
        now = Date()
        if now >= endsAt { end(); return }
        let engine = model.engine
        if engine.screenLocked || engine.displayAsleep { awaySeconds += 1; return }
        let app = NSWorkspace.shared.frontmostApplication?.localizedName
        if model.screenTime.isDistracting(app) {
            distractingSeconds += 1; distractingStreak += 1
            // A nudge after 20 seconds in a distracting app, at most once a minute.
            if distractingStreak >= 20 && now.timeIntervalSince(lastNudge) > 60 {
                lastNudge = now
                model.notifier.deliver(AlertContent(kind: .nudge, title: "Back to focus: \(clock) left",
                                                    body: "\(finished.count) of \(picked.count) done. \(app ?? "This app") is on your distracting list.",
                                                    symbol: "scope", tint: .pink), channels: [.banner])
            }
        } else {
            distractingStreak = 0
        }
    }

    func end() {
        guard running else { return }
        timer?.invalidate(); timer = nil
        running = false
        let end = min(Date(), endsAt)
        let elapsed = max(1, Int(end.timeIntervalSince(startedAt)))
        let lost = min(elapsed, awaySeconds + distractingSeconds)
        let percent = Int((100 * Double(elapsed - lost) / Double(elapsed)).rounded())
        var s = FocusSession(id: sessionID, startedAt: startedAt, endedAt: end, plannedMinutes: minutes,
                             actualMinutes: Int((Double(elapsed) / 60).rounded()), picked: picked.count, finished: finished.count,
                             points: Focus.points(finished: finished.count, picked: picked.count, focusPercent: percent))
        s.finishedIds = finished
        s.finishedTitles = finished.compactMap { occurrence($0)?.task.title }
        s.awaySeconds = awaySeconds; s.distractingSeconds = distractingSeconds; s.focusPercent = percent
        model.store.saveFocusSession(s)
        result = s
        model.notifier.deliver(AlertContent(kind: .nudge, title: "Time! \(s.finished) done",
                                            body: "\(percent)% focused · +\(s.points) points. Write your reflections to check them off.",
                                            symbol: "scope", tint: .pink), channels: model.store.settings.defaultChannels)
        model.screen = .focus
        model.windows.showMain()
    }

    /// "taskID|yyyy-MM-dd" → the occurrence.
    func occurrence(_ id: String) -> Occurrence? {
        let parts = id.split(separator: "|").map(String.init)
        guard parts.count == 2, let uuid = UUID(uuidString: parts[0]), let t = model.store.task(uuid),
              let day = DateKey.date(parts[1]) else { return nil }
        return Occurrence(task: t, day: day)
    }
}
