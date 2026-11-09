import SwiftUI
import UserNotifications

// Study on iPhone: the three session modes, courses, flashcards and notes. Shares the model with the Mac.

/// Runs a study session on this phone. Notifications for each switch are scheduled ahead, so they arrive with
/// the app closed. In a no-phone session, time with Cadence open on screen counts as phone use.
@MainActor
final class MobileStudy: ObservableObject {
    private let store: Store
    private var timer: Timer?
    @Published var run: StudyRun? { didSet { persist(); reschedule() } }
    @Published private(set) var now = Date()
    @Published var lastLog: StudyLog?
    var active = true

    private var file: URL { LaunchOptions.dataDirectory.appendingPathComponent("studyRun.json") }

    init(store: Store) {
        self.store = store
        if let data = try? Data(contentsOf: file) {
            let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
            run = try? d.decode(StudyRun.self, from: data)
        }
        startTimer()
    }

    private func persist() {
        guard let run else { try? FileManager.default.removeItem(at: file); return }
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try? e.encode(run).write(to: file, options: .atomic)
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        now = Date()
        guard let r = run, !r.paused else { return }
        if r.mode == .timed, r.timedState(now).finished { finish(); return }
        if r.mode == .offline, active { run?.screenSeconds += 1 }
    }

    func start(_ r: StudyRun) { lastLog = nil; run = r; now = Date() }
    func update(_ change: (inout StudyRun) -> Void) { guard var r = run else { return }; change(&r); run = r; now = Date() }

    func finish() {
        guard let r = run else { return }
        let log = r.log(Date())
        if log.minutes > 0 || log.completed > 0 { store.saveStudyLog(log) }
        if r.mode == .dynamic, let id = r.courseID { store.editCourse(id) { $0.phase = r.phase } }
        run = nil
        lastLog = log
    }

    func discard() { run = nil }

    func addMistake(_ text: String, card: Bool) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        update { $0.mistakes.append(t) }
        if let id = run?.courseID {
            store.editCourse(id) { c in
                c.mistakes.append(Mistake(text: t))
                if card { c.cards.append(Flashcard(front: t, back: "")) }
            }
        }
    }

    /// Notifications for the switches still ahead (round, break, period end, time's up).
    func reschedule() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { reqs in
            let old = reqs.map(\.identifier).filter { $0.hasPrefix("study-") }
            center.removePendingNotificationRequests(withIdentifiers: old)
        }
        guard let r = run, !r.paused else { return }
        let now = Date(), done = r.elapsed(now)
        var events: [(Double, String, String)] = []   // (seconds of study time, title, body)
        switch r.mode {
        case .timed:
            var t = 0.0
            for n in 1...max(1, r.rounds) {
                t += Double(r.studyMinutes * 60)
                if n == r.rounds { events.append((t, "Study session done", "\(r.rounds) rounds of \(r.title). Nice work.")) }
                else {
                    events.append((t, "Break: \(r.breakMinutes) min", "Round \(n) of \(r.rounds) done. Stand up and stretch."))
                    t += Double(r.breakMinutes * 60)
                    events.append((t, "Round \(n + 1) of \(r.rounds)", "Back to \(r.title)."))
                }
            }
        case .dynamic:
            if !r.taskBased, !r.wrapUp, let p = r.period {
                let next = r.periods.indices.contains(r.index + 1) ? r.periods[r.index + 1].title : "wrap up"
                events.append((r.periodStart + Double(p.minutes * 60), "Time's up: \(p.title)", "Next: \(next)."))
            }
        case .offline:
            if r.plannedMinutes > 0 { events.append((Double(r.plannedMinutes * 60), "Time's up", "\(r.plannedMinutes) min of \(r.title) away from the phone. Open Cadence to log it.")) }
        }
        for (i, e) in events.enumerated() where e.0 > done + 1 {
            let c = UNMutableNotificationContent()
            c.title = e.1; c.body = e.2; c.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: e.0 - done, repeats: false)
            center.add(UNNotificationRequest(identifier: "study-\(i)", content: c, trigger: trigger))
        }
    }
}

// MARK: - Study screen

struct StudyScreen: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var study: MobileStudy

    var body: some View {
        Group {
            if study.run != nil { MobileRunningStudy() } else { MobileStudySetup() }
        }
        .navigationTitle("Study")
    }
}

private struct MobileStudySetup: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var study: MobileStudy
    @AppStorage("studyMode") private var mode: StudyMode = .dynamic
    @AppStorage("studyCourse") private var courseKey = ""
    @AppStorage("studyMinutes") private var studyMinutes = 25
    @AppStorage("studyBreak") private var breakMinutes = 5
    @AppStorage("studyRounds") private var rounds = 4
    @AppStorage("studyOffline") private var offlineMinutes = 60
    @State private var title = ""

    private var course: Course? { UUID(uuidString: courseKey).flatMap(store.course) }

    var body: some View {
        List {
            if let l = study.lastLog {
                Section {
                    Label("Logged \(durationString(seconds: l.minutes * 60)) of \(l.title)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            Section {
                Picker("Mode", selection: $mode) { ForEach(StudyMode.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                Text(mode.blurb).font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Picker("Course", selection: $courseKey) {
                    Text("No course").tag("")
                    ForEach(store.activeCourses) { Text($0.title).tag($0.id.uuidString) }
                }
                TextField("What you're studying", text: $title)
                switch mode {
                case .timed:
                    Stepper("Study \(studyMinutes) min", value: $studyMinutes, in: 5...240, step: 5)
                    Stepper("Break \(breakMinutes) min", value: $breakMinutes, in: 0...60)
                    Stepper("\(rounds) round\(rounds == 1 ? "" : "s")", value: $rounds, in: 1...12)
                case .dynamic:
                    if let c = course {
                        LabeledContent("Phase", value: c.phase.title)
                        let r = c.rules(for: c.phase)
                        LabeledContent("Homework", value: r.homework.title)
                        LabeledContent("Quiz", value: r.quiz.title)
                        if !c.openMistakes.isEmpty { Label("You'll start with \(c.openMistakes.count) thing(s) you got wrong", systemImage: "arrow.uturn.backward.circle").foregroundStyle(.orange) }
                    }
                    Text((course?.activePeriods ?? StudyPeriod.classPeriod).map(\.title).joined(separator: " → ")).font(.footnote).foregroundStyle(.secondary)
                case .offline:
                    Picker("How long", selection: $offlineMinutes) {
                        ForEach([30, 45, 60, 90, 120, 180], id: \.self) { Text(durationString(seconds: $0 * 60)).tag($0) }
                        Text("Until I stop").tag(0)
                    }
                }
            } footer: {
                if mode == .offline { Text("Put the phone face down or in another room. Time with Cadence open counts as phone use.") }
            }
            Section {
                Button { start() } label: { Label("Start \(mode.title.lowercased()) session", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
            }
            Section("Progress") {
                LabeledContent("Today", value: durationString(seconds: store.studyMinutes(on: Date()) * 60))
                LabeledContent("Streak", value: "\(store.studyStreak) day\(store.studyStreak == 1 ? "" : "s")")
                NavigationLink { StudyHistoryScreen() } label: { Text("History") }
                NavigationLink { CoursesScreen() } label: { Text("Courses").badge(store.activeCourses.count) }
            }
        }
    }

    private func start() {
        let t = title.trimmingCharacters(in: .whitespaces)
        var r = StudyRun.make(mode, course: course, title: t.isEmpty ? (course.map { $0.chapter.isEmpty ? $0.title : "\($0.title): \($0.chapter)" } ?? "") : t)
        r.studyMinutes = studyMinutes; r.breakMinutes = breakMinutes; r.rounds = rounds; r.plannedMinutes = offlineMinutes
        study.start(r)
        title = ""
    }
}

private struct MobileRunningStudy: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var study: MobileStudy
    @State private var mistake = ""
    @State private var asCard = false
    @State private var confirmEnd = false

    var body: some View {
        if let r = study.run {
            let course = store.course(r.courseID)
            List {
                Section {
                    VStack(spacing: 6) {
                        Label(r.mode.title, systemImage: r.mode.symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(r.title).font(.title3.bold()).multilineTextAlignment(.center)
                        clock(r)
                        if r.paused { Text("Paused").foregroundStyle(.orange) }
                    }
                    .frame(maxWidth: .infinity)
                    HStack {
                        Button { study.update { $0.togglePause() } } label: { Label(r.paused ? "Resume" : "Pause", systemImage: r.paused ? "play.fill" : "pause.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.bordered)
                        Button { confirmEnd = true } label: { Text("End").frame(maxWidth: .infinity) }.buttonStyle(.bordered)
                    }
                    .listRowBackground(Color.clear)
                }
                if r.mode == .dynamic { classPeriod(r, course) }
                if r.mode == .offline {
                    Section {
                        Label(r.screenSeconds < 10 ? "Phone not used so far" : "Cadence open \(durationString(seconds: r.screenSeconds))",
                              systemImage: r.screenSeconds < 10 ? "checkmark.circle" : "iphone")
                            .foregroundStyle(r.screenSeconds < 10 ? .green : .orange)
                    } footer: { Text("Put the phone down. You'll get a notification when the time's up.") }
                }
            }
            .confirmationDialog("End this session?", isPresented: $confirmEnd, titleVisibility: .visible) {
                Button("End and log") { study.finish() }
                Button("Discard it", role: .destructive) { study.discard() }
            }
        }
    }

    @ViewBuilder private func clock(_ r: StudyRun) -> some View {
        let now = study.now
        let (secs, caption): (Int, String) = {
            switch r.mode {
            case .timed: let st = r.timedState(now); return (st.secondsLeft, st.onBreak ? "break · round \(st.round) of \(r.rounds)" : "round \(st.round) of \(r.rounds)")
            case .dynamic: return r.taskBased || r.wrapUp ? (Int(r.elapsed(now)), "so far") : (r.periodSecondsLeft(now), r.period?.title ?? "")
            case .offline: return r.offlineSecondsLeft(now).map { ($0, "left") } ?? (Int(r.elapsed(now)), "away")
            }
        }()
        Text(clockString(secs)).font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit()).foregroundStyle(secs < 0 ? .orange : .primary)
        Text(caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private func classPeriod(_ r: StudyRun, _ course: Course?) -> some View {
        if let c = course {
            let rules = c.rules(for: r.phase)
            Section {
                LabeledContent("Phase", value: r.phase.title)
                LabeledContent("Homework", value: rules.homework.title)
                LabeledContent("Quiz", value: rules.quiz.title)
            }
        }
        Section("Cycle \(r.cycle)") {
            ForEach(Array(r.periods.enumerated()), id: \.element.id) { i, p in
                Button { study.update { $0.index = i; $0.wrapUp = false; $0.periodStart = $0.elapsed() } } label: {
                    HStack {
                        Image(systemName: i < r.index || r.wrapUp ? "checkmark.circle.fill" : i == r.index ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(i == r.index && !r.wrapUp ? Color.accentColor : .secondary)
                        Text(p.title).foregroundStyle(.primary).fontWeight(i == r.index && !r.wrapUp ? .semibold : .regular)
                        Spacer()
                        Text(r.taskBased ? "\(p.tasks.count) tasks" : "\(p.minutes) min").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        if r.wrapUp {
            Section("Cycle \(r.cycle) done") {
                Button("Repeat \(r.phase.title.lowercased())") { study.update { $0.repeatCycle(phase: r.phase) } }
                if let next = r.phase.next { Button("Move on to \(next.title.lowercased())") { study.update { $0.repeatCycle(phase: next) } } }
                Button("Finish and log") { study.finish() }
            }
        } else if let p = r.period {
            Section {
                if !p.blurb.isEmpty { Text(p.blurb).font(.callout).foregroundStyle(.secondary) }
                ForEach(Array(p.tasks.enumerated()), id: \.offset) { i, t in
                    Button { study.update { $0.toggle(p, i) } } label: {
                        Label(t, systemImage: r.isChecked(p, i) ? "checkmark.square.fill" : "square").foregroundStyle(r.isChecked(p, i) ? .secondary : .primary)
                    }
                }
                if r.index == 0, let c = course {
                    ForEach(c.openMistakes) { m in
                        Label(m.text, systemImage: "arrow.uturn.backward.circle").foregroundStyle(.orange)
                            .swipeActions { Button("Got it") { store.editCourse(c.id) { cc in if let k = cc.mistakes.firstIndex(where: { $0.id == m.id }) { cc.mistakes[k].resolvedAt = Date() } } }.tint(.green) }
                    }
                }
                if p.kind == .quiz || p.kind == .officeHours {
                    TextField(p.kind == .quiz ? "Something you got wrong" : "Something to come back to", text: $mistake)
                        .onSubmit { study.addMistake(mistake, card: asCard); mistake = "" }
                    if course != nil { Toggle("Also make a flashcard", isOn: $asCard) }
                }
                if !r.taskBased { Button("+5 min") { study.update { $0.periodStart += 300 } } }
                Button {
                    study.update { $0.nextPeriod() }
                } label: {
                    Label("Next: \(r.periods.indices.contains(r.index + 1) ? r.periods[r.index + 1].title : "Wrap up")", systemImage: "arrow.right")
                }
                .fontWeight(.semibold)
            } header: { Text(p.title) }
        }
    }
}

struct StudyHistoryScreen: View {
    @EnvironmentObject private var store: Store
    var body: some View {
        List {
            ForEach(store.sortedStudyLogs) { l in
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text(l.title); Spacer(); Text(durationString(seconds: l.minutes * 60)).monospacedDigit() }
                    Text([l.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()), l.mode.title, l.phase.map { "\($0.title) phase" }]
                        .compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions { Button("Delete", role: .destructive) { store.studyLogs.removeAll { $0.id == l.id } } }
            }
        }
        .navigationTitle("History")
        .overlay { if store.studyLogs.isEmpty { ContentUnavailableView("No sessions yet", systemImage: "graduationcap") } }
    }
}

// MARK: - Courses

struct CoursesScreen: View {
    @EnvironmentObject private var store: Store
    @State private var open: UUID?
    var body: some View {
        List {
            ForEach(store.activeCourses) { c in
                Button { open = c.id } label: {
                    HStack {
                        RoundedRectangle(cornerRadius: 2).fill(c.color.color).frame(width: 4, height: 30)
                        VStack(alignment: .leading) {
                            Text(c.title).foregroundStyle(.primary)
                            Text("\(c.phase.title)\(c.chapter.isEmpty ? "" : " · \(c.chapter)")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .swipeActions { Button("Delete", role: .destructive) { store.deleteCourse(c.id) } }
            }
        }
        .navigationTitle("Courses")
        .toolbar { Button { let c = Course(title: "New course", color: TaskColor.allCases.randomElement() ?? .blue); store.upsert(c); open = c.id } label: { Image(systemName: "plus") } }
        .navigationDestination(item: $open) { CourseScreen(id: $0) }
        .overlay { if store.activeCourses.isEmpty { ContentUnavailableView("No courses yet", systemImage: "graduationcap", description: Text("A course is a subject you study, with its own class period and phase.")) } }
    }
}

struct CourseScreen: View {
    @EnvironmentObject private var store: Store
    let id: UUID
    @State private var newTask: [UUID: String] = [:]
    private var c: Course { store.course(id) ?? Course(title: "") }
    private func edit(_ f: (inout Course) -> Void) { store.editCourse(id, f) }

    var body: some View {
        Form {
            Section {
                TextField("Course name", text: Binding(get: { c.title }, set: { v in edit { $0.title = v } })).font(.headline)
                TextField("What you're on now", text: Binding(get: { c.chapter }, set: { v in edit { $0.chapter = v } }))
                Picker("Color", selection: Binding(get: { c.color }, set: { v in edit { $0.color = v } })) {
                    ForEach(TaskColor.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
            Section {
                Picker("Phase", selection: Binding(get: { c.phase }, set: { v in edit { $0.phase = v } })) {
                    ForEach(StudyPhase.allCases) { Text($0.title).tag($0) }
                }
                ForEach(StudyPhase.allCases) { p in
                    DisclosureGroup(p.title) {
                        Picker("Homework", selection: rule(p, \.homework)) { ForEach(NoteRule.allCases) { Text($0.title).tag($0) } }
                        Picker("Quiz", selection: rule(p, \.quiz)) { ForEach(NoteRule.allCases) { Text($0.title).tag($0) } }
                    }
                }
            } header: { Text("Phase") } footer: { Text(c.phase.blurb) }
            Section {
                Picker("Each period ends", selection: Binding(get: { c.taskBased }, set: { v in edit { $0.taskBased = v } })) {
                    Text("On time").tag(false); Text("By tasks").tag(true)
                }
                .pickerStyle(.segmented)
                ForEach(Array(c.periods.enumerated()), id: \.element.id) { i, p in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Toggle(isOn: Binding(get: { p.enabled }, set: { v in edit { $0.periods[i].enabled = v } })) {
                                TextField("Period", text: Binding(get: { c.periods.indices.contains(i) ? c.periods[i].title : "" }, set: { v in edit { $0.periods[i].title = v } }))
                            }
                        }
                        if !c.taskBased {
                            Stepper("\(p.minutes) min", value: Binding(get: { p.minutes }, set: { v in edit { $0.periods[i].minutes = v } }), in: 1...240, step: 5)
                        }
                        ForEach(Array(p.tasks.enumerated()), id: \.offset) { ti, t in
                            HStack { Image(systemName: "square").foregroundStyle(.secondary); Text(t).font(.callout); Spacer()
                                Button { edit { $0.periods[i].tasks.remove(at: ti) } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless) }
                        }
                        TextField("Add a task", text: Binding(get: { newTask[p.id] ?? "" }, set: { newTask[p.id] = $0 }))
                            .font(.callout)
                            .onSubmit {
                                let t = (newTask[p.id] ?? "").trimmingCharacters(in: .whitespaces)
                                guard !t.isEmpty else { return }
                                edit { $0.periods[i].tasks.append(t) }; newTask[p.id] = ""
                            }
                    }
                    .opacity(p.enabled ? 1 : 0.5)
                }
                .onDelete { idx in edit { $0.periods.remove(atOffsets: idx) } }
                .onMove { from, to in edit { $0.periods.move(fromOffsets: from, toOffset: to) } }
                Menu("Add a period") { ForEach(PeriodKind.allCases) { k in Button(k.defaultTitle) { edit { $0.periods.append(StudyPeriod(kind: k)) } } } }
            } header: { Text("Class period") }
            if !c.openMistakes.isEmpty {
                Section("What you got wrong") {
                    ForEach(c.openMistakes) { m in
                        Text(m.text).swipeActions { Button("Got it") { edit { cc in if let k = cc.mistakes.firstIndex(where: { $0.id == m.id }) { cc.mistakes[k].resolvedAt = Date() } } }.tint(.green) }
                    }
                }
            }
        }
        .navigationTitle(c.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func rule(_ p: StudyPhase, _ key: WritableKeyPath<PhaseRules, NoteRule>) -> Binding<NoteRule> {
        Binding(get: { c.rules(for: p)[keyPath: key] }, set: { v in edit { var r = $0.rules(for: p); r[keyPath: key] = v; $0.rules[p.rawValue] = r } })
    }
}

// MARK: - Flashcards

struct FlashcardsScreen: View {
    @EnvironmentObject private var store: Store
    @State private var reviewing = false
    @State private var front = ""
    @State private var back = ""
    @AppStorage("cardsAddTo") private var addTo = ""

    var body: some View {
        let courses = store.activeCourses
        List {
            Section {
                HStack {
                    VStack(alignment: .leading) {
                        Text("\(store.dueCardCount)").font(.largeTitle.bold().monospacedDigit())
                        Text("cards due today").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Review") { reviewing = true }.buttonStyle(.borderedProminent).disabled(store.dueCardCount == 0)
                }
            }
            if courses.isEmpty {
                Text("Flashcards belong to a course. Make one under Study › Courses first.").foregroundStyle(.secondary)
            } else {
                Section("New card") {
                    Picker("Course", selection: Binding(get: { UUID(uuidString: addTo).flatMap(store.course)?.id.uuidString ?? courses[0].id.uuidString }, set: { addTo = $0 })) {
                        ForEach(courses) { Text($0.title).tag($0.id.uuidString) }
                    }
                    TextField("Front (question)", text: $front, axis: .vertical)
                    TextField("Back (answer)", text: $back, axis: .vertical)
                    Button("Add card") {
                        let id = UUID(uuidString: addTo).flatMap(store.course)?.id ?? courses[0].id
                        store.editCourse(id) { $0.cards.append(Flashcard(front: front.trimmingCharacters(in: .whitespaces), back: back.trimmingCharacters(in: .whitespaces))) }
                        front = ""; back = ""
                    }
                    .disabled(front.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(courses) { c in
                    if !c.cards.isEmpty {
                        Section(c.title) {
                            ForEach(c.cards) { k in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(k.front)
                                    Text(k.back.isEmpty ? "(no answer)" : k.back).font(.caption).foregroundStyle(.secondary)
                                }
                                .badge(k.isDue() ? Text("due") : nil)
                                .swipeActions { Button("Delete", role: .destructive) { store.editCourse(c.id) { $0.cards.removeAll { $0.id == k.id } } } }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Flashcards")
        .sheet(isPresented: $reviewing) { MobileCardReview() }
    }
}

private struct MobileCardReview: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var queue: [(UUID, UUID)] = []
    @State private var shown = false
    @State private var reviewed = 0
    @State private var started = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                if let (cid, kid) = queue.first, let c = store.course(cid), let card = c.cards.first(where: { $0.id == kid }) {
                    Text(c.title).font(.caption.weight(.semibold)).foregroundStyle(c.color.color)
                    Text(card.front).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    if shown {
                        Divider()
                        Text(card.back.isEmpty ? "(no answer written)" : card.back).font(.title3).multilineTextAlignment(.center)
                        Spacer()
                        HStack {
                            ForEach(Flashcard.Grade.allCases, id: \.rawValue) { g in
                                Button(g.title) {
                                    store.editCourse(cid) { cc in if let i = cc.cards.firstIndex(where: { $0.id == kid }) { cc.cards[i].review(g) } }
                                    reviewed += 1; queue.removeFirst()
                                    if g == .again { queue.append((cid, kid)) }
                                    shown = false
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(g == .again ? .red : g == .hard ? .orange : g == .good ? .green : .blue)
                                .frame(maxWidth: .infinity)
                            }
                        }
                    } else {
                        Spacer()
                        Button { shown = true } label: { Text("Show answer").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                } else {
                    Spacer()
                    Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(.green)
                    Text(reviewed == 0 ? "Nothing due." : "All done: \(reviewed) reviewed.").font(.headline)
                    Spacer()
                }
            }
            .padding()
            .navigationTitle("\(reviewed) reviewed · \(queue.count) left")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .onAppear {
                guard !started else { return }
                started = true
                queue = store.activeCourses.flatMap { c in c.dueCards().map { (c.id, $0.id) } }.shuffled()
            }
        }
    }
}

// MARK: - Notes

struct NotesScreen: View {
    @EnvironmentObject private var store: Store
    @State private var open: UUID?
    @State private var search = ""
    var body: some View {
        List {
            ForEach(store.sortedNotes.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.body.localizedCaseInsensitiveContains(search) }) { n in
                Button { open = n.id } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { if n.pinned == true { Image(systemName: "pin.fill").foregroundStyle(.orange).font(.caption) }; Text(n.displayTitle).foregroundStyle(.primary) }
                        Text(n.body.replacingOccurrences(of: "\n", with: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { store.deleteNote(n.id) }
                    Button(n.pinned == true ? "Unpin" : "Pin") { var m = n; m.pinned = n.pinned == true ? nil : true; store.upsert(m) }.tint(.orange)
                }
            }
        }
        .searchable(text: $search)
        .navigationTitle("Notes")
        .toolbar { Button { let n = Note(); store.upsert(n); open = n.id } label: { Image(systemName: "square.and.pencil") } }
        .navigationDestination(item: $open) { NoteScreen(id: $0) }
        .overlay { if store.notes.isEmpty { ContentUnavailableView("No notes yet", systemImage: "note.text") } }
    }
}

struct NoteScreen: View {
    @EnvironmentObject private var store: Store
    let id: UUID
    @State private var title = ""
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $title).font(.title2.bold())
                .onChange(of: title) { _, v in if loaded { save { $0.title = v } } }
            TextEditor(text: $text)
                .onChange(of: text) { _, v in if loaded { save { $0.body = v } } }
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let n = store.notes.first(where: { $0.id == id }) { title = n.title; text = n.body }
            loaded = true
        }
    }

    private func save(_ change: (inout Note) -> Void) {
        guard var n = store.notes.first(where: { $0.id == id }) else { return }
        change(&n)
        store.upsert(n)
    }
}
