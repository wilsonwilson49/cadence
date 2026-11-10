import Foundation

// Study: three ways to run a study session, plus courses, flashcards and notes.
//
//  - Timed: study / break rounds on a clock.
//  - Class period ("dynamic"): Lecture → Any questions? → Homework → Office hours → Quiz, then repeat the
//    phase or move on. Each period ends on time or when its tasks are done (per course). The course's
//    phase (Reading → Learning → Understanding → Testing) says what's open-note.
//  - No computer: a timer for studying away from the screen; using the computer during it is noted.
//
// Courses, session logs and notes sync (kinds "course", "study", "note"). A running session stays on the
// device that started it. The same shapes and rules are in web/public/js/model.js.

enum StudyMode: String, Codable, CaseIterable, Identifiable {
    case timed, dynamic, offline
    var id: String { rawValue }
    var title: String { self == .timed ? "Timed" : self == .dynamic ? "Intervals" : "No computer" }
    /// The modes you can start (timed sessions are now just an interval preset; old logs keep the name).
    static let startable: [StudyMode] = [.dynamic, .offline]
    var symbol: String { self == .timed ? "timer" : self == .dynamic ? "graduationcap" : "book.closed" }
    var blurb: String {
        switch self {
        case .timed: return "Study and break on a clock, for as many rounds as you like."
        case .dynamic: return "Run a preset of intervals: the class period, 25 on / 5 off, or your own. Every length is adjustable."
        case .offline: return "Put the computer away and study on paper. Cadence keeps time and notes if you come back to the screen."
        }
    }
}

/// How far into the material you are. Overlaps a lot with the class periods; it's guidance, not a rule.
enum StudyPhase: String, Codable, CaseIterable, Identifiable {
    case reading, learning, understanding, testing
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var blurb: String {
        switch self {
        case .reading: return "The chapter seems like a pile of words and you don't understand it yet."
        case .learning: return "You're beginning to understand."
        case .understanding: return "You understand it; now make it stick."
        case .testing: return "Test yourself the way the real test will."
        }
    }
    var next: StudyPhase? {
        let all = Self.allCases
        guard let i = all.firstIndex(of: self), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
    var defaultRules: PhaseRules {
        switch self {
        case .reading: return PhaseRules(homework: .open, quiz: .open)
        case .learning: return PhaseRules(homework: .open, quiz: .closed)
        case .understanding: return PhaseRules(homework: .open, quiz: .closed)
        case .testing: return PhaseRules(homework: .textbook, quiz: .closed)
        }
    }
}

enum NoteRule: String, Codable, CaseIterable, Identifiable {
    case open, textbook, closed
    var id: String { rawValue }
    var title: String { self == .open ? "Open note" : self == .textbook ? "Textbook only" : "Closed note" }
}

struct PhaseRules: Codable, Hashable {
    var homework: NoteRule
    var quiz: NoteRule
}

enum PeriodKind: String, Codable, CaseIterable, Identifiable {
    case lecture, questions, homework, officeHours, quiz, custom, study, breakTime
    var id: String { rawValue }
    var defaultTitle: String {
        switch self {
        case .lecture: return "Lecture"
        case .questions: return "Any questions?"
        case .homework: return "Homework"
        case .officeHours: return "Office hours"
        case .quiz: return "Quiz"
        case .custom: return "Your own period"
        case .study: return "Study"
        case .breakTime: return "Break"
        }
    }
    var defaultBlurb: String {
        switch self {
        case .lecture: return "The whole chapter, just an info dump. Go slowly so you pick up a lot; take what you can and leave the rest for later. Memorization can wait."
        case .questions: return "Your chance to begin understanding. Ask AI, ask a partner, look things up."
        case .homework: return "Solve as many problems as you can. Ask AI, check the back of the textbook."
        case .officeHours: return "Ask about the problems you got stuck on: a friend who's studying it, AI, a teacher. Learn as much as you can."
        case .quiz: return "Try to retain as much as you can. Write down what you got wrong; you'll start there next session."
        case .custom, .study: return ""
        case .breakTime: return "Stand up, stretch, drink some water, look away from the screen."
        }
    }
    var symbol: String {
        switch self {
        case .lecture: return "text.book.closed"
        case .questions: return "questionmark.bubble"
        case .homework: return "pencil.and.list.clipboard"
        case .officeHours: return "person.2"
        case .quiz: return "checkmark.seal"
        case .custom: return "star"
        case .study: return "book"
        case .breakTime: return "cup.and.saucer"
        }
    }
    var defaultMinutes: Int {
        switch self {
        case .lecture: return 30
        case .questions: return 10
        case .homework: return 30
        case .officeHours: return 15
        case .quiz: return 15
        case .custom: return 15
        case .study: return 25
        case .breakTime: return 5
        }
    }
    /// Which note rule applies in this period (lecture and questions are always open).
    func rule(_ r: PhaseRules) -> NoteRule? {
        switch self {
        case .homework, .officeHours: return r.homework
        case .quiz: return r.quiz
        default: return nil
        }
    }
}

struct StudyPeriod: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: PeriodKind
    var title: String
    var minutes: Int
    var enabled = true
    /// For task-based periods: what to get done before moving on.
    var tasks: [String] = []
    var blurb: String

    init(kind: PeriodKind, title: String? = nil, minutes: Int? = nil, tasks: [String] = []) {
        self.kind = kind; self.title = title ?? kind.defaultTitle; self.minutes = minutes ?? kind.defaultMinutes
        self.tasks = tasks; self.blurb = kind.defaultBlurb
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); kind = c.value(.kind, PeriodKind.custom)
        title = c.value(.title, kind.defaultTitle); minutes = max(1, c.value(.minutes, kind.defaultMinutes))
        enabled = c.value(.enabled, true); tasks = c.value(.tasks, []); blurb = c.value(.blurb, kind.defaultBlurb)
    }

    static var classPeriod: [StudyPeriod] { [.lecture, .questions, .homework, .officeHours, .quiz].map { StudyPeriod(kind: $0) } }
}

/// Something you got wrong in a quiz: you start there next session.
struct Mistake: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var addedAt = Date()
    var resolvedAt: Date?

    init(text: String) { self.text = text }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); text = c.value(.text, ""); addedAt = c.value(.addedAt, Date()); resolvedAt = c.value(.resolvedAt, nil as Date?)
    }
}

/// A flashcard, reviewed with simple spaced repetition.
struct Flashcard: Codable, Identifiable, Hashable {
    var id = UUID()
    var front: String
    var back: String
    /// "yyyy-MM-dd": next review.
    var due: String = DateKey.string(Date())
    var intervalDays = 0
    var ease = 2.5
    var reps = 0
    var createdAt = Date()

    init(front: String, back: String) { self.front = front; self.back = back }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); front = c.value(.front, ""); back = c.value(.back, "")
        due = c.value(.due, DateKey.string(Date())); intervalDays = c.value(.intervalDays, 0)
        ease = c.value(.ease, 2.5); reps = c.value(.reps, 0); createdAt = c.value(.createdAt, Date())
    }

    enum Grade: Int, CaseIterable { case again, hard, good, easy
        var title: String { ["Again", "Hard", "Good", "Easy"][rawValue] }
    }

    func isDue(today: Date = Date()) -> Bool { due <= DateKey.string(today) }

    /// After a review. Again: back in the pile today. Hard / Good / Easy: further out each time. Same as reviewCard() on the web.
    mutating func review(_ g: Grade, today: Date = Date()) {
        switch g {
        case .again: intervalDays = 0; ease = max(1.3, ease - 0.2); reps = 0
        case .hard: intervalDays = max(1, Int((Double(intervalDays) * 1.2).rounded())); ease = max(1.3, ease - 0.15); reps += 1
        case .good: intervalDays = intervalDays == 0 ? 1 : intervalDays == 1 ? 3 : Int((Double(intervalDays) * ease).rounded()); reps += 1
        case .easy: intervalDays = max(4, Int((Double(max(1, intervalDays)) * ease * 1.3).rounded())); ease += 0.15; reps += 1
        }
        due = DateKey.string(Calendar.current.date(byAdding: .day, value: intervalDays, to: today.startOfDay) ?? today)
    }
}

/// A subject you study ("Chemistry", "CS"): its class period, phase, what you got wrong, and its flashcards.
struct Course: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var color: TaskColor = .blue
    /// What you're on right now ("Ch. 4: Stoichiometry").
    var chapter = ""
    var phase: StudyPhase = .reading
    /// Each period ends when its time is up (false) or when its tasks are done (true).
    var taskBased = false
    var periods: [StudyPeriod] = StudyPeriod.classPeriod
    /// Phase raw value → note rules, when you've changed them from the defaults.
    var rules: [String: PhaseRules] = [:]
    var mistakes: [Mistake] = []
    var cards: [Flashcard] = []
    /// How many times to run the intervals in a row.
    var repeats = 1
    /// Move to the next interval by itself when its time is up.
    var autoAdvance = false
    /// Show the phase, note rules and "what you got wrong" (the class-period way of studying).
    var showPhase = true
    var createdAt = Date()
    var updatedAt: Date?
    var archived: Bool?

    init(title: String, color: TaskColor = .blue) { self.title = title; self.color = color }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); title = c.value(.title, ""); color = c.value(.color, TaskColor.blue)
        chapter = c.value(.chapter, ""); phase = c.value(.phase, StudyPhase.reading); taskBased = c.value(.taskBased, false)
        periods = c.value(.periods, StudyPeriod.classPeriod); rules = c.value(.rules, [:])
        mistakes = c.value(.mistakes, []); cards = c.value(.cards, [])
        repeats = max(1, c.value(.repeats, 1)); autoAdvance = c.value(.autoAdvance, false); showPhase = c.value(.showPhase, true)
        createdAt = c.value(.createdAt, Date()); updatedAt = c.value(.updatedAt, nil as Date?); archived = c.value(.archived, nil as Bool?)
    }

    func rules(for p: StudyPhase) -> PhaseRules { rules[p.rawValue] ?? p.defaultRules }
    var openMistakes: [Mistake] { mistakes.filter { $0.resolvedAt == nil } }
    func dueCards(today: Date = Date()) -> [Flashcard] { cards.filter { $0.isDue(today: today) } }
    var activePeriods: [StudyPeriod] { periods.filter(\.enabled) }
    var cycleMinutes: Int { activePeriods.reduce(0) { $0 + $1.minutes } }

    /// Built-in presets to start from.
    enum Template: String, CaseIterable, Identifiable {
        case classPeriod, pomodoro, long, deep, blank
        var id: String { rawValue }
        var title: String {
            switch self {
            case .classPeriod: return "Class period"
            case .pomodoro: return "25 on / 5 off × 4"
            case .long: return "50 on / 10 off × 3"
            case .deep: return "90 on / 15 off × 2"
            case .blank: return "Blank"
            }
        }
    }
    static func template(_ t: Template) -> Course {
        func onOff(_ on: Int, _ off: Int, _ n: Int) -> Course {
            var c = Course(title: "\(on) / \(off)", color: .teal)
            c.periods = [StudyPeriod(kind: .study, minutes: on), StudyPeriod(kind: .breakTime, minutes: off)]
            c.repeats = n; c.autoAdvance = true; c.showPhase = false
            return c
        }
        switch t {
        case .classPeriod: var c = Course(title: "Class period", color: .purple); c.showPhase = true; return c
        case .pomodoro: return onOff(25, 5, 4)
        case .long: return onOff(50, 10, 3)
        case .deep: return onOff(90, 15, 2)
        case .blank:
            var c = Course(title: "New preset", color: .blue)
            c.periods = [StudyPeriod(kind: .study)]; c.showPhase = false; c.autoAdvance = true
            return c
        }
    }

    static func demo() -> [Course] {
        var chem = Course(title: "Chemistry", color: .green)
        chem.chapter = "Ch. 4: Stoichiometry"; chem.phase = .learning
        chem.periods[2].tasks = ["Problems 1–15 (odd)", "Check answers in the back"]
        chem.mistakes = [Mistake(text: "Limiting reagent: compare moles ÷ coefficient, not grams")]
        chem.cards = [Flashcard(front: "Avogadro's number", back: "6.022 × 10²³ per mole"),
                      Flashcard(front: "Molar mass of water", back: "18.02 g/mol")]
        var cs = Course(title: "CS", color: .purple)
        cs.chapter = "Graphs: shortest paths"; cs.taskBased = true; cs.phase = .understanding
        cs.periods = [StudyPeriod(kind: .lecture, tasks: ["Read the editorial on Dijkstra", "Skim 0-1 BFS"]),
                      StudyPeriod(kind: .homework, tasks: ["Solve 2 problems rated 1600+"]),
                      StudyPeriod(kind: .quiz, tasks: ["Re-implement Dijkstra from memory"])]
        return [chem, cs]
    }
}

/// A finished study session (any mode).
struct StudyLog: Codable, Identifiable, Equatable {
    var id = UUID()
    var mode: StudyMode
    var courseID: UUID?
    var title: String
    var startedAt: Date
    var endedAt: Date
    var minutes: Int
    var phase: StudyPhase?
    /// Class period: periods finished. Timed: rounds finished.
    var completed = 0
    /// No computer: seconds the computer was in use during the session.
    var screenSeconds = 0
    var note = ""
    var updatedAt: Date?

    init(mode: StudyMode, courseID: UUID?, title: String, startedAt: Date, endedAt: Date) {
        self.mode = mode; self.courseID = courseID; self.title = title; self.startedAt = startedAt; self.endedAt = endedAt
        minutes = max(0, Int((endedAt.timeIntervalSince(startedAt) / 60).rounded()))
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); mode = c.value(.mode, StudyMode.timed); courseID = c.value(.courseID, nil as UUID?)
        title = c.value(.title, ""); startedAt = c.value(.startedAt, Date()); endedAt = c.value(.endedAt, Date())
        minutes = c.value(.minutes, 0); phase = c.value(.phase, nil as StudyPhase?); completed = c.value(.completed, 0)
        screenSeconds = c.value(.screenSeconds, 0); note = c.value(.note, ""); updatedAt = c.value(.updatedAt, nil as Date?)
    }
}

/// A plain note (Notes tool).
struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var body = ""
    var pinned: Bool?
    var createdAt = Date()
    var updatedAt: Date?

    init(title: String = "", body: String = "") { self.title = title; self.body = body }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID()); title = c.value(.title, ""); body = c.value(.body, "")
        pinned = c.value(.pinned, nil as Bool?); createdAt = c.value(.createdAt, Date()); updatedAt = c.value(.updatedAt, nil as Date?)
    }
    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        return body.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces).prefix(60).description ?? "Untitled"
    }
}

// MARK: - Sync

/// A record that syncs on its own (last writer wins), stamped with updatedAt.
protocol SyncedRecord: Codable, Equatable, Identifiable where ID == UUID {
    var updatedAt: Date? { get set }
    var stampFallback: Date { get }
}
extension Course: SyncedRecord { var stampFallback: Date { createdAt } }
extension StudyLog: SyncedRecord { var stampFallback: Date { endedAt } }
extension Note: SyncedRecord { var stampFallback: Date { createdAt } }

// MARK: - A running session (kept on the device that started it)

struct StudyRun: Codable, Equatable {
    var mode: StudyMode
    var courseID: UUID?
    var title: String
    var startedAt = Date()
    var pausedAt: Date?
    var pausedSeconds: Double = 0
    // Timed
    var studyMinutes = 25
    var breakMinutes = 5
    var rounds = 4
    // Class period
    var taskBased = false
    var periods: [StudyPeriod] = []
    var index = 0
    /// Study time (pauses left out) when the current period began.
    var periodStart: Double = 0
    /// "periodID|task index" for ticked tasks.
    var checked: [String] = []
    var phase: StudyPhase = .reading
    var cycle = 1
    var wrapUp = false
    var repeats: Int?
    var autoAdvance: Bool?
    var showPhase: Bool?
    // No computer
    var plannedMinutes = 60
    var screenSeconds = 0
    /// Things you got wrong this session (class period quiz, or any time).
    var mistakes: [String] = []

    var paused: Bool { pausedAt != nil }

    /// Seconds of study time so far, pauses left out.
    func elapsed(_ now: Date = Date()) -> Double {
        let end = pausedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - pausedSeconds)
    }

    mutating func togglePause(_ now: Date = Date()) {
        if let p = pausedAt { pausedSeconds += now.timeIntervalSince(p); pausedAt = nil } else { pausedAt = now }
    }

    // Timed: which round, study or break, and seconds left in it.
    struct TimedState: Equatable { var round: Int; var onBreak: Bool; var secondsLeft: Int; var finished: Bool }
    func timedState(_ now: Date = Date()) -> TimedState {
        let s = Double(max(1, studyMinutes) * 60), b = Double(max(0, breakMinutes) * 60)
        var t = elapsed(now)
        for r in 1...max(1, rounds) {
            if t < s { return TimedState(round: r, onBreak: false, secondsLeft: Int((s - t).rounded(.up)), finished: false) }
            t -= s
            if r == rounds { break }
            if t < b { return TimedState(round: r, onBreak: true, secondsLeft: Int((b - t).rounded(.up)), finished: false) }
            t -= b
        }
        return TimedState(round: rounds, onBreak: false, secondsLeft: 0, finished: true)
    }
    var timedTotalMinutes: Int { studyMinutes * rounds + breakMinutes * max(0, rounds - 1) }

    // Class period
    var period: StudyPeriod? { periods.indices.contains(index) ? periods[index] : nil }
    func periodSecondsLeft(_ now: Date = Date()) -> Int {
        guard let p = period else { return 0 }
        return Int((Double(p.minutes * 60) - (elapsed(now) - periodStart)).rounded(.up))
    }
    func isChecked(_ p: StudyPeriod, _ i: Int) -> Bool { checked.contains("\(p.id)|\(i)") }
    mutating func toggle(_ p: StudyPeriod, _ i: Int) {
        let k = "\(p.id)|\(i)"
        if let at = checked.firstIndex(of: k) { checked.remove(at: at) } else { checked.append(k) }
    }
    func periodTasksDone(_ p: StudyPeriod) -> Bool { !p.tasks.isEmpty && p.tasks.indices.allSatisfy { isChecked(p, $0) } }
    mutating func nextPeriod(_ now: Date = Date()) {
        if index + 1 < periods.count { index += 1; periodStart = elapsed(now) }
        else if cycle < (repeats ?? 1) { repeatCycle(phase: phase, now) }
        else { wrapUp = true }
    }
    /// Change the current interval's length (it keeps the time already spent).
    mutating func setMinutes(_ m: Int) { if periods.indices.contains(index) { periods[index].minutes = min(480, max(1, m)) } }
    /// After the quiz: go through the class period again (same phase or the next).
    mutating func repeatCycle(phase newPhase: StudyPhase, _ now: Date = Date()) {
        phase = newPhase; index = 0; cycle += 1; checked = []; wrapUp = false; periodStart = elapsed(now)
    }

    // No computer
    func offlineSecondsLeft(_ now: Date = Date()) -> Int? {
        plannedMinutes > 0 ? Int((Double(plannedMinutes * 60) - elapsed(now)).rounded(.up)) : nil
    }

    /// The log to save when it ends.
    func log(_ now: Date = Date()) -> StudyLog {
        var l = StudyLog(mode: mode, courseID: courseID, title: title, startedAt: startedAt, endedAt: now)
        l.minutes = Int((elapsed(now) / 60).rounded())
        switch mode {
        case .timed:
            let st = timedState(now)
            l.completed = st.finished ? rounds : st.round - (st.onBreak ? 0 : 1)
        case .dynamic:
            l.phase = phase
            l.completed = (cycle - 1) * periods.count + (wrapUp ? periods.count : index)
        case .offline:
            l.screenSeconds = screenSeconds
        }
        if !mistakes.isEmpty { l.note = "Got wrong: " + mistakes.joined(separator: "; ") }
        return l
    }

    static func make(_ mode: StudyMode, course: Course?, title: String) -> StudyRun {
        var r = StudyRun(mode: mode, courseID: course?.id, title: title.isEmpty ? (course?.title ?? mode.title) : title)
        if let c = course {
            r.periods = c.activePeriods.isEmpty ? StudyPeriod.classPeriod : c.activePeriods
            r.taskBased = c.taskBased
            r.phase = c.phase
            r.repeats = c.repeats; r.autoAdvance = c.autoAdvance; r.showPhase = c.showPhase
        } else {
            r.periods = StudyPeriod.classPeriod
        }
        return r
    }
}

func clockString(_ seconds: Int) -> String {
    let s = abs(seconds)
    let str = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    return seconds < 0 ? "+" + str : str
}
