import SwiftUI
import UserNotifications
import Combine

/// Cadence for iPhone: the same account, checklist, habits and focus sessions as the Mac and the web.
@main
struct CadenceMobileApp: App {
    @StateObject private var model = MobileModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            MobileRoot()
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.sync)
                .environmentObject(model.focus)
                .tint(.pink)
        }
        .onChange(of: phase) { _, p in model.scenePhaseChanged(p) }
    }
}

/// What a reflection sheet is for: checking an item off, or "didn't do it".
struct ReflectTarget: Identifiable {
    let occ: Occurrence
    let missed: Bool
    var id: String { occ.id + (missed ? "|missed" : "") }
}

@MainActor
final class MobileModel: ObservableObject {
    static let shared = MobileModel()

    let store: Store
    let sync: SyncService
    let focus: MobileFocus

    @Published var tab = 0
    @Published var reflecting: ReflectTarget?
    @Published var editing: PlanTask?
    @Published var notificationsAllowed = false

    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private init() {
        store = Store(directory: LaunchOptions.dataDirectory)
        sync = SyncService(store: store)
        focus = MobileFocus(store: store)
        focus.model = nil
    }

    func start() {
        guard !started else { return }
        started = true
        focus.model = self
        #if DEBUG
        // Test runs: -server <url> -login <user> <password> -tab <n> -noNotifyPrompt
        if let server = LaunchOptions.value("-server") { sync.serverURL = server }
        if let i = LaunchOptions.args.firstIndex(of: "-login"), i + 2 < LaunchOptions.args.count, !sync.isSignedIn {
            let user = LaunchOptions.args[i + 1], pass = LaunchOptions.args[i + 2]
            Task { await sync.signIn(username: user, password: pass, create: false) }
        }
        if LaunchOptions.has("-demo") && store.tasks.isEmpty { DemoData.seed(store) }
        if let t = LaunchOptions.value("-tab").flatMap(Int.init) { tab = t }
        if let what = LaunchOptions.value("-open") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                switch what {
                case "newhabit": newHabit()
                case "edit": editing = store.tasks.first { $0.isHabit && $0.habit?.style == "stack" } ?? store.tasks.first
                case "reflect": if let o = store.todayChecklist().first(where: { !$0.isResolved }) { reflect(o) }
                default: break
                }
            }
        }
        if LaunchOptions.has("-noNotifyPrompt") { sync.start(); return }
        #endif
        sync.start()
        // Re-plan the reminder notifications a moment after anything changes.
        store.objectWillChange
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] in self?.scheduleNotifications() }
            .store(in: &cancellables)
        Task {
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            notificationsAllowed = granted
            scheduleNotifications()
        }
    }

    func scenePhaseChanged(_ p: ScenePhase) {
        switch p {
        case .active:
            start()
            sync.sync()
            focus.cameBack()
        case .background:
            focus.wentAway()
            store.saveNow()
            scheduleNotifications()
        default: break
        }
    }

    // MARK: Actions

    func reflect(_ occ: Occurrence, missed: Bool = false) {
        if let t = store.task(occ.task.id) { reflecting = ReflectTarget(occ: Occurrence(task: t, day: occ.day), missed: missed) }
    }

    func toggle(_ occ: Occurrence) {
        if occ.isDone { store.uncomplete(occ) } else { reflect(occ) }
    }

    func toggleMissed(_ occ: Occurrence) {
        if occ.isMissed { store.unmiss(occ) } else { reflect(occ, missed: true) }
    }

    func newTask(on day: Date = Date()) {
        var t = PlanTask(title: "", startDate: day.startOfDay, channels: store.settings.defaultChannels)
        t.kind = "task"; t.busy = false
        editing = t
    }

    func newHabit() {
        var t = PlanTask(title: "", startDate: Date().startOfDay, recurrence: Recurrence(frequency: .daily),
                         channels: store.settings.defaultChannels, color: .green)
        t.kind = "habit"; t.busy = false; t.habit = HabitInfo()
        editing = t
    }

    func newEvent(on day: Date = Date()) {
        let now = Date()
        let m = day.isSameDay(now) ? min(23 * 60, (Calendar.current.component(.hour, from: now) + 1) * 60) : 9 * 60
        var t = PlanTask(title: "", startDate: day.startOfDay, timeMinutes: m, durationMinutes: 60,
                         reminderOffsets: [10], channels: store.settings.defaultChannels, color: .teal)
        t.kind = "event"; t.busy = true
        editing = t
    }

    func occurrence(_ id: String) -> Occurrence? {
        let parts = id.split(separator: "|").map(String.init)
        guard parts.count == 2, let uuid = UUID(uuidString: parts[0]), let t = store.task(uuid), let day = DateKey.date(parts[1]) else { return nil }
        return Occurrence(task: t, day: day)
    }

    // MARK: Notifications

    /// iPhone apps can't run a timer in the background, so reminders are planned ahead as local notifications:
    /// each item's reminders for today and the next two days, plus a morning check-in. Re-planned on every change.
    func scheduleNotifications() {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard notificationsAllowed else { return }
        let s = store.settings
        let now = Date()
        var requests: [UNNotificationRequest] = []
        for offset in 0...2 {
            let day = now.startOfDay.adding(days: offset)
            for occ in store.occurrences(on: day) where !occ.isResolved && !occ.task.isSilent {
                let base = occ.start ?? dayAt(day, minutes: s.untimedReminderMinutes)
                for off in occ.task.reminderOffsets.sorted() {
                    let fire = base.adding(minutes: -off)
                    guard fire > now else { continue }
                    let c = UNMutableNotificationContent()
                    c.title = occ.task.title
                    if occ.isEvent {
                        c.body = occ.start.map { off == 0 ? "Starting now (\(timeString($0)))" : "Starts at \(timeString($0)) — \(offsetString(off))" } ?? "Today"
                    } else {
                        c.body = occ.start.map { off < 0 ? offsetString(off) : off == 0 ? "Starting now (\(timeString($0)))" : "At \(timeString($0)) — \(offsetString(off))" }
                            ?? "On today's checklist"
                        c.body += ". Check it off with a reflection when you're done."
                    }
                    c.sound = .default
                    c.userInfo = ["occ": occ.id]
                    let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                    requests.append(UNNotificationRequest(identifier: "\(occ.id)|\(off)", content: c,
                                                          trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
                }
            }
        }
        // iOS keeps at most 64 pending notifications; keep the soonest.
        requests.sort { ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture
            < ($1.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantFuture }
        for r in requests.prefix(58) { center.add(r) }
        // A check-in every morning, like the computer apps do when you open your laptop.
        if s.checkInOnLaunch {
            let c = UNMutableNotificationContent()
            c.title = "Time to check in"
            c.body = "Open Cadence to see today's checklist and habits."
            c.sound = .default
            center.add(UNNotificationRequest(identifier: "checkin", content: c,
                                             trigger: UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: 8, minute: 30), repeats: true)))
        }
        if focus.running {
            let c = UNMutableNotificationContent()
            c.title = "Time! Your focus session is over"
            c.body = "Open Cadence to see your score and write your reflections."
            c.sound = .default
            center.add(UNNotificationRequest(identifier: "focus-end", content: c,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, focus.endsAt.timeIntervalSinceNow), repeats: false)))
        }
        // The app icon shows how many items are left today.
        center.setBadgeCount(store.remainingToday)
    }
}

/// Focus sessions on the iPhone: same scoring as the Mac and web. Time spent outside Cadence counts as away.
@MainActor
final class MobileFocus: ObservableObject {
    private let store: Store
    weak var model: MobileModel?
    private var timer: Timer?
    private var awaySince: Date?
    private var id = UUID()

    @Published private(set) var running = false
    @Published private(set) var startedAt = Date()
    @Published private(set) var endsAt = Date()
    @Published private(set) var minutes = 25
    @Published private(set) var picked: [String] = []
    @Published private(set) var finished: [String] = []
    @Published private(set) var awaySeconds = 0
    @Published private(set) var now = Date()
    @Published var result: FocusSession?

    init(store: Store) { self.store = store }

    var secondsLeft: Int { max(0, Int(endsAt.timeIntervalSince(now).rounded(.up))) }
    var clock: String { String(format: "%d:%02d", secondsLeft / 60, secondsLeft % 60) }

    func start(minutes: Int, picked: [String]) {
        self.minutes = minutes; self.picked = picked; finished = []; awaySeconds = 0; awaySince = nil
        startedAt = Date(); endsAt = startedAt.addingTimeInterval(Double(minutes * 60)); now = startedAt
        id = UUID(); result = nil; running = true
        tickTimer()
        model?.scheduleNotifications()
    }

    private func tickTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.now = Date()
                if self.now >= self.endsAt { self.end() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func toggleFinished(_ occID: String) {
        if let i = finished.firstIndex(of: occID) { finished.remove(at: i) } else { finished.append(occID) }
        if !picked.isEmpty && finished.count == picked.count { end() }
    }

    func addFiveMinutes() { endsAt = endsAt.addingTimeInterval(300); minutes += 5; model?.scheduleNotifications() }

    func wentAway() { if running && awaySince == nil { awaySince = Date() } }

    func cameBack() {
        guard running else { return }
        if let a = awaySince { awaySeconds += Int(min(Date(), endsAt).timeIntervalSince(a)); awaySince = nil }
        now = Date()
        if now >= endsAt { end() } else { tickTimer() }
    }

    func end() {
        guard running else { return }
        timer?.invalidate(); timer = nil
        running = false
        let end = min(Date(), endsAt)
        if let a = awaySince { awaySeconds += Int(max(0, end.timeIntervalSince(a))); awaySince = nil }
        let elapsed = max(1, Int(end.timeIntervalSince(startedAt)))
        let percent = Int((100 * Double(elapsed - min(elapsed, awaySeconds)) / Double(elapsed)).rounded())
        var s = FocusSession(id: id, startedAt: startedAt, endedAt: end, plannedMinutes: minutes,
                             actualMinutes: Int((Double(elapsed) / 60).rounded()), picked: picked.count, finished: finished.count,
                             points: Focus.points(finished: finished.count, picked: picked.count, focusPercent: percent))
        s.finishedIds = finished
        s.finishedTitles = finished.compactMap { model?.occurrence($0)?.task.title }
        s.awaySeconds = awaySeconds; s.focusPercent = percent; s.device = "ios"
        store.saveFocusSession(s)
        result = s
        model?.tab = 3
        model?.scheduleNotifications()
    }
}

#if DEBUG
/// Sample data for App Store screenshots (-demo on a fresh install).
enum DemoData {
    @MainActor static func seed(_ store: Store) {
        let today = Date().startOfDay
        func task(_ title: String, _ color: TaskColor, time: Int? = nil, day: Int = 0) -> PlanTask {
            var t = PlanTask(title: title, startDate: today.adding(days: day), timeMinutes: time, channels: [.notification], color: color)
            t.kind = "task"; t.busy = false
            return t
        }
        func habit(_ title: String, _ color: TaskColor, _ freq: Frequency = .daily, weekdays: [Int] = [], style: String = "build",
                   done: [Int], missed: [Int] = [], set: (inout HabitInfo) -> Void = { _ in }) -> PlanTask {
            var t = PlanTask(title: title, startDate: today.adding(days: -14), recurrence: Recurrence(frequency: freq, weekdays: weekdays),
                             channels: [.notification], color: color)
            t.kind = "habit"; t.busy = false
            var h = HabitInfo(); h.style = style; set(&h); t.habit = h
            for d in done { t.completions[DateKey.string(today.adding(days: -d))] = today.adding(days: -d) }
            if !missed.isEmpty { t.missed = Dictionary(uniqueKeysWithValues: missed.map { (DateKey.string(today.adding(days: -$0)), today.adding(days: -$0)) }) }
            return t
        }
        var essay = task("Finish history essay", .orange); essay.mode = "untilDone"; essay.dueDate = today.adding(days: 2); essay.startDate = today.adding(days: -1)
        var standup = task("Team standup", .teal, time: 10 * 60); standup.kind = "event"; standup.busy = true; standup.durationMinutes = 15
        var dentist = task("Dentist", .purple, time: 15 * 60 + 30); dentist.kind = "event"; dentist.busy = true; dentist.durationMinutes = 60
        var email = task("Email Professor Kim", .blue, time: 11 * 60)
        email.completions[DateKey.string(today)] = Date()
        store.tasks = [
            email, task("Pick up groceries", .green, time: 17 * 60 + 30), task("Plan the weekend trip", .pink), essay, standup, dentist,
            habit("Meditate for one minute", .green, style: "stack", done: Array(1...12)) { $0.stackAfter = "pour my morning coffee"; $0.identity = "takes care of their mind"; $0.twoMinute = "three deep breaths" },
            habit("Read 20 pages", .blue, done: [1, 2, 3, 5, 6, 7, 8, 9, 11, 12, 13], missed: [4]) { $0.cue = "at 9 PM on the couch"; $0.identity = "reads every day"; $0.twoMinute = "read one page" },
            habit("Morning run", .orange, .weekly, weekdays: [2, 4, 6],
                  done: (1...14).filter { [2, 4, 6].contains(Calendar.current.component(.weekday, from: today.adding(days: -$0))) }) { $0.reward = "a smoothie"; $0.identity = "is a runner" },
            habit("Phone stays out of bed", .purple, style: "replace", done: [0, 1, 2, 3, 5, 6]) { $0.replaces = "scrolling in bed"; $0.identity = "sleeps well" },
        ]
        store.reflections = [
            Reflection(taskID: email.id, taskTitle: email.title, occurrenceKey: DateKey.string(today),
                       text: "Sent the draft outline and asked about the sources for the second section. Felt good to get it off my plate before lunch instead of carrying it around all day."),
        ]
        for (i, n) in [(1, 3), (2, 4), (4, 2)] {
            let start = today.adding(days: -i).addingTimeInterval(16 * 3600)
            var s = FocusSession(startedAt: start, endedAt: start.addingTimeInterval(1500), plannedMinutes: 25, actualMinutes: 25,
                                 picked: n + 1, finished: n, points: Focus.points(finished: n, picked: n + 1, focusPercent: 92))
            s.focusPercent = 92; s.device = "ios"
            store.saveFocusSession(s)
        }
    }
}
#endif
