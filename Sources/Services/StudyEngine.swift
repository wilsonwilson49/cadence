import AppKit
import Foundation

/// Runs a study session on this Mac: keeps time, says when a round or period is over, notices computer use in a
/// no-computer session, and saves the log when it ends. The running session is kept in studyRun.json, so it
/// survives quitting Cadence.
@MainActor
final class StudyEngine: ObservableObject {
    private unowned let model: AppModel
    private var timer: Timer?
    private var notified: Set<String> = []
    private var lastScreenNudge = Date.distantPast
    private var pendingScreen = 0

    @Published var run: StudyRun? { didSet { persist() } }
    @Published private(set) var now = Date()
    /// The session that just ended, for the summary.
    @Published var lastLog: StudyLog?

    private var file: URL { LaunchOptions.dataDirectory.appendingPathComponent("studyRun.json") }

    init(model: AppModel) {
        self.model = model
        if let data = try? Data(contentsOf: file) {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            run = try? d.decode(StudyRun.self, from: data)
        }
        if run != nil { startTimer() }
    }

    private func persist() {
        guard let run else { try? FileManager.default.removeItem(at: file); return }
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try? e.encode(run).write(to: file, options: .atomic)
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func start(_ r: StudyRun) {
        notified = []; pendingScreen = 0; lastLog = nil
        run = r
        now = Date()
        startTimer()
    }

    /// Change the running session (tick a task, next period, pause…).
    func update(_ change: (inout StudyRun) -> Void) {
        guard var r = run else { return }
        r.screenSeconds += pendingScreen; pendingScreen = 0
        change(&r)
        run = r
        now = Date()
    }

    private func notify(_ title: String, _ body: String, symbol: String = "graduationcap") {
        model.notifier.deliver(AlertContent(kind: .nudge, title: title, body: body, symbol: symbol, tint: .indigo),
                               channels: [.notification, .banner, .sound])
    }

    private func tick() {
        now = Date()
        guard let r = run, !r.paused else { return }
        switch r.mode {
        case .timed:
            let st = r.timedState(now)
            if st.finished { notify("Study session done", "\(r.rounds) round\(r.rounds == 1 ? "" : "s") of \(r.title). Nice work."); finish(); return }
            let key = "\(st.round)|\(st.onBreak)"
            if notified.insert(key).inserted, !(st.round == 1 && !st.onBreak) {
                if st.onBreak { notify("Break: \(r.breakMinutes) min", "Round \(st.round) of \(r.rounds) done. Stand up, stretch, look away from the screen.", symbol: "cup.and.saucer") }
                else { notify("Round \(st.round) of \(r.rounds)", "Back to \(r.title).", symbol: "timer") }
            }
        case .dynamic:
            guard !r.taskBased, !r.wrapUp, let p = r.period else { break }
            if r.periodSecondsLeft(now) <= 0, notified.insert("p\(r.cycle)|\(r.index)").inserted {
                let next = r.periods.indices.contains(r.index + 1) ? r.periods[r.index + 1].title : "wrap up"
                notify("Time's up: \(p.title)", "Next: \(next). Move on when you're ready.", symbol: p.kind.symbol)
            }
        case .offline:
            // Using the Mac during a no-computer session: it's noted, with a reminder every couple of minutes.
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            let away = model.engine.screenLocked || model.engine.displayAsleep
            if !away && idle < 2 {
                pendingScreen += 1
                if pendingScreen + r.screenSeconds >= 20, now.timeIntervalSince(lastScreenNudge) > 120 {
                    lastScreenNudge = now
                    notify("No-computer session", "You're on the computer. Back to \(r.title) on paper?", symbol: "book.closed")
                }
            }
            if pendingScreen >= 15 { update { _ in } }
            if let left = r.offlineSecondsLeft(now), left <= 0, notified.insert("offline-done").inserted {
                notify("Time's up", "\(r.plannedMinutes) min of \(r.title) away from the screen. End the session in Cadence to log it.", symbol: "book.closed")
            }
        }
    }

    /// Ends the session and saves the log. Class period: the course keeps the phase you're in.
    func finish() {
        guard var r = run else { return }
        r.screenSeconds += pendingScreen; pendingScreen = 0
        let log = r.log(Date())
        if log.minutes > 0 || log.completed > 0 { model.store.saveStudyLog(log) }
        if r.mode == .dynamic, let id = r.courseID { model.store.editCourse(id) { $0.phase = r.phase } }
        timer?.invalidate(); timer = nil
        run = nil
        lastLog = log
    }

    /// Stops without saving anything.
    func discard() {
        timer?.invalidate(); timer = nil
        run = nil
    }

    /// Something you got wrong: kept on the course, so next session starts there.
    func addMistake(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        update { $0.mistakes.append(t) }
        if let id = run?.courseID { model.store.editCourse(id) { $0.mistakes.append(Mistake(text: t)) } }
    }
}
