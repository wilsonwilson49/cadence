import SwiftUI

/// Study: start a session (timed, class period, or no computer), program your courses, see what you've done.
struct StudyView: View {
    @EnvironmentObject private var study: StudyEngine
    @AppStorage("studyTab") private var tab = "session"

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Study", subtitle: "Timed rounds, a class-period cycle, or time away from the screen.") {
                Picker("", selection: $tab) {
                    Text("Session").tag("session"); Text("Courses").tag("courses"); Text("History").tag("history")
                }
                .pickerStyle(.segmented).fixedSize()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch tab {
                    case "courses": CoursesPanel()
                    case "history": StudyHistory()
                    default:
                        if study.run != nil { RunningStudy() } else { StudySetup() }
                    }
                }
                .padding(22)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Starting a session

private struct StudySetup: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var study: StudyEngine
    @AppStorage("studyMode") private var mode: StudyMode = .dynamic
    @AppStorage("studyCourse") private var courseKey = ""
    @AppStorage("studyMinutes") private var studyMinutes = 25
    @AppStorage("studyBreak") private var breakMinutes = 5
    @AppStorage("studyRounds") private var rounds = 4
    @AppStorage("studyOffline") private var offlineMinutes = 60
    @State private var title = ""
    @State private var taskBasedOverride: Bool?

    private var course: Course? { UUID(uuidString: courseKey).flatMap(store.course) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let last = study.lastLog { lastSummary(last) }
            HStack(spacing: 12) {
                ForEach(StudyMode.allCases) { m in
                    Button { mode = m } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(m.title, systemImage: m.symbol).font(.headline)
                            Text(m.blurb).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 12).fill(mode == m ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(mode == m ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: mode == m ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker("Course", selection: $courseKey) {
                            Text("No course").tag("")
                            ForEach(store.activeCourses) { c in Text(c.title).tag(c.id.uuidString) }
                        }
                        .frame(maxWidth: 260)
                        Button("New course…") { newCourse() }.controlSize(.small)
                        Spacer()
                    }
                    TextField(course.map { "What you're studying (default: \($0.chapter.isEmpty ? $0.title : $0.chapter))" } ?? "What you're studying, e.g. Ch. 4 problems",
                              text: $title)
                        .textFieldStyle(.roundedBorder)
                    switch mode {
                    case .timed: timedOptions
                    case .dynamic: dynamicOptions
                    case .offline: offlineOptions
                    }
                    HStack {
                        Spacer()
                        Button { start() } label: { Label("Start \(mode.title.lowercased()) session", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            StudyStats()
        }
        .onChange(of: courseKey) { _, _ in taskBasedOverride = nil }
    }

    private var timedOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ForEach([(25, 5, 4), (50, 10, 3), (90, 15, 2)], id: \.0) { s, b, r in
                    Button("\(s)/\(b) × \(r)") { studyMinutes = s; breakMinutes = b; rounds = r }
                        .buttonStyle(.bordered).tint(studyMinutes == s && breakMinutes == b && rounds == r ? .accentColor : nil)
                }
            }
            HStack(spacing: 18) {
                Stepper("Study \(studyMinutes) min", value: $studyMinutes, in: 5...240, step: 5)
                Stepper("Break \(breakMinutes) min", value: $breakMinutes, in: 0...60, step: 1)
                Stepper("\(rounds) round\(rounds == 1 ? "" : "s")", value: $rounds, in: 1...12)
            }
            .fixedSize()
            Text("About \(durationString(seconds: (studyMinutes * rounds + breakMinutes * max(0, rounds - 1)) * 60)) in all. You'll get a notification at every switch.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var dynamicOptions: some View {
        let periods = course?.activePeriods ?? StudyPeriod.classPeriod
        let taskBased = taskBasedOverride ?? course?.taskBased ?? false
        VStack(alignment: .leading, spacing: 10) {
            if let c = course {
                PhaseBanner(course: c)
                if !c.openMistakes.isEmpty {
                    Label("You'll start with \(c.openMistakes.count) thing\(c.openMistakes.count == 1 ? "" : "s") you got wrong last time.", systemImage: "arrow.uturn.backward.circle")
                        .font(.callout).foregroundStyle(.orange)
                }
            } else {
                Text("No course: you'll use the standard class period. Make a course to program your own periods, tasks and phase.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Each period ends", selection: Binding(get: { taskBased }, set: { taskBasedOverride = $0 })) {
                Text("When its time is up").tag(false)
                Text("When its tasks are done").tag(true)
            }
            .pickerStyle(.segmented).fixedSize()
            HStack(spacing: 6) {
                ForEach(Array(periods.enumerated()), id: \.element.id) { i, p in
                    if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    VStack(spacing: 2) {
                        Label(p.title, systemImage: p.kind.symbol).font(.caption.weight(.semibold)).lineLimit(1)
                        Text(taskBased ? "\(p.tasks.count) task\(p.tasks.count == 1 ? "" : "s")" : "\(p.minutes) min").font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
            }
            Text(taskBased ? "Tick off each period's tasks, then move on. Programmed per course under Courses."
                 : "About \(durationString(seconds: periods.reduce(0) { $0 + $1.minutes } * 60)) for one cycle. Then repeat the phase or move on.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var offlineOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("How long", selection: $offlineMinutes) {
                ForEach([30, 45, 60, 90, 120, 180], id: \.self) { Text(durationString(seconds: $0 * 60)).tag($0) }
                Text("Until I stop").tag(0)
            }
            .fixedSize()
            Text("Close the laptop or walk away from it. If you use the computer during the session, Cadence notes it and reminds you.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func newCourse() {
        let c = Course(title: "New course", color: TaskColor.allCases.randomElement() ?? .blue)
        store.upsert(c)
        courseKey = c.id.uuidString
        UserDefaults.standard.set("courses", forKey: "studyTab")
        UserDefaults.standard.set(c.id.uuidString, forKey: "studyEditingCourse")
    }

    private func start() {
        let t = title.trimmingCharacters(in: .whitespaces)
        var r = StudyRun.make(mode, course: course, title: t.isEmpty ? (course.map { $0.chapter.isEmpty ? $0.title : "\($0.title): \($0.chapter)" } ?? "") : t)
        r.studyMinutes = studyMinutes; r.breakMinutes = breakMinutes; r.rounds = rounds
        r.plannedMinutes = offlineMinutes
        if let o = taskBasedOverride { r.taskBased = o }
        study.start(r)
        title = ""
    }

    private func lastSummary(_ l: StudyLog) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Logged \(durationString(seconds: l.minutes * 60)) of \(l.title)").font(.headline)
                Text([l.mode.title,
                      l.mode == .dynamic ? "\(l.completed) period\(l.completed == 1 ? "" : "s")" : l.mode == .timed ? "\(l.completed) round\(l.completed == 1 ? "" : "s")" : nil,
                      l.mode == .offline ? (l.screenSeconds > 30 ? "computer used \(durationString(seconds: l.screenSeconds))" : "screen-free") : nil,
                      l.phase.map { "\($0.title) phase" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { study.lastLog = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.10)))
    }
}

/// The course's phase and what's open-note in it.
struct PhaseBanner: View {
    let course: Course
    var phase: StudyPhase?

    var body: some View {
        let p = phase ?? course.phase
        let r = course.rules(for: p)
        HStack(spacing: 10) {
            Text(p.title.uppercased()).font(.caption.weight(.heavy)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(course.color.color))
            Text(p.blurb).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            RuleChip(label: "Homework", rule: r.homework)
            RuleChip(label: "Quiz", rule: r.quiz)
        }
    }
}

struct RuleChip: View {
    let label: String
    let rule: NoteRule
    var body: some View {
        let c: Color = rule == .open ? .green : rule == .textbook ? .orange : .red
        HStack(spacing: 4) {
            Image(systemName: rule == .open ? "book" : rule == .textbook ? "text.book.closed" : "book.closed.fill").font(.system(size: 9))
            Text("\(label): \(rule.title)")
        }
        .font(.caption2.weight(.semibold)).foregroundStyle(c)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(c.opacity(0.13)))
    }
}

// MARK: - A running session

private struct RunningStudy: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var study: StudyEngine
    @State private var confirmEnd = false

    var body: some View {
        if let r = study.run {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(r.mode.title, systemImage: r.mode.symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(r.title).font(.title2.bold())
                    }
                    Spacer()
                    Text("\(clockString(Int(r.elapsed(study.now)))) so far").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Button { study.update { $0.togglePause() } } label: {
                        Label(r.paused ? "Resume" : "Pause", systemImage: r.paused ? "play.fill" : "pause.fill")
                    }
                    Button("End…") { confirmEnd = true }
                }
                switch r.mode {
                case .timed: TimedRunView(run: r)
                case .dynamic: ClassPeriodRunView(run: r)
                case .offline: OfflineRunView(run: r)
                }
                if r.paused {
                    Label("Paused. The clock picks up where it left off.", systemImage: "pause.circle").foregroundStyle(.orange)
                }
            }
            .confirmationDialog("End this session?", isPresented: $confirmEnd) {
                Button("End and log \(durationString(seconds: Int(r.elapsed(study.now))))") { study.finish() }
                Button("Discard it", role: .destructive) { study.discard() }
            } message: {
                Text("Ending logs the time under History.")
            }
        }
    }
}

private struct BigClock: View {
    let seconds: Int
    let fraction: Double
    let caption: String
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.15), lineWidth: 12)
            Circle().trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 1), value: fraction)
            VStack(spacing: 2) {
                Text(clockString(seconds)).font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(seconds < 0 ? .orange : .primary)
                Text(caption).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(width: 200, height: 200)
    }
}

private struct TimedRunView: View {
    @EnvironmentObject private var study: StudyEngine
    let run: StudyRun

    var body: some View {
        let st = run.timedState(study.now)
        let total = Double((st.onBreak ? run.breakMinutes : run.studyMinutes) * 60)
        Card {
            HStack(spacing: 30) {
                BigClock(seconds: st.secondsLeft, fraction: Double(st.secondsLeft) / max(1, total),
                         caption: st.onBreak ? "break" : "studying", tint: st.onBreak ? .green : .accentColor)
                VStack(alignment: .leading, spacing: 10) {
                    Text(st.onBreak ? "Break" : "Round \(st.round) of \(run.rounds)").font(.title3.bold())
                    Text(st.onBreak ? "Stand up, stretch, drink some water, look away from the screen." : "Just \(run.title). Phone away.")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        ForEach(1...max(1, run.rounds), id: \.self) { i in
                            Capsule().fill(i < st.round || (i == st.round && st.onBreak) ? Color.accentColor : i == st.round ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.2))
                                .frame(width: 26, height: 7)
                        }
                    }
                    Text("\(run.studyMinutes) min study · \(run.breakMinutes) min break").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }
}

private struct OfflineRunView: View {
    @EnvironmentObject private var study: StudyEngine
    let run: StudyRun

    var body: some View {
        let left = run.offlineSecondsLeft(study.now)
        let elapsed = Int(run.elapsed(study.now))
        Card {
            HStack(spacing: 30) {
                BigClock(seconds: left ?? elapsed, fraction: left.map { Double($0) / Double(max(1, run.plannedMinutes * 60)) } ?? 1,
                         caption: left == nil ? "away" : (left ?? 0) < 0 ? "over" : "left", tint: .teal)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Away from the screen").font(.title3.bold())
                    Text("Close the laptop or walk away. Paper, textbook, whiteboard. Come back and end the session when you're done.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Label(run.screenSeconds < 10 ? "Computer not used so far" : "Computer used \(durationString(seconds: run.screenSeconds)) so far",
                          systemImage: run.screenSeconds < 10 ? "checkmark.circle" : "desktopcomputer")
                        .foregroundStyle(run.screenSeconds < 10 ? .green : .orange)
                }
                Spacer()
            }
        }
    }
}

private struct ClassPeriodRunView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var study: StudyEngine
    let run: StudyRun
    @State private var mistake = ""
    @State private var asCard = false
    @State private var newChapter = ""

    var body: some View {
        let course = store.course(run.courseID)
        VStack(alignment: .leading, spacing: 14) {
            if let c = course { PhaseBanner(course: c, phase: run.phase) }
            // The cycle, with where you are.
            HStack(spacing: 6) {
                Text("Cycle \(run.cycle)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(run.periods.enumerated()), id: \.element.id) { i, p in
                    Button { study.update { $0.index = i; $0.wrapUp = false; $0.periodStart = $0.elapsed() } } label: {
                        Label(p.title, systemImage: i < run.index || run.wrapUp ? "checkmark.circle.fill" : p.kind.symbol)
                            .font(.caption.weight(i == run.index && !run.wrapUp ? .bold : .regular))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(i == run.index && !run.wrapUp ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.05)))
                            .foregroundStyle(i < run.index || run.wrapUp ? .secondary : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            if run.wrapUp { wrapUp(course) } else if let p = run.period { periodCard(p, course) }
        }
    }

    @ViewBuilder private func periodCard(_ p: StudyPeriod, _ course: Course?) -> some View {
        let left = run.periodSecondsLeft(study.now)
        let rule = course.map { p.kind.rule($0.rules(for: run.phase)) } ?? p.kind.rule(run.phase.defaultRules)
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 24) {
                    if !run.taskBased {
                        BigClock(seconds: left, fraction: Double(left) / Double(max(1, p.minutes * 60)), caption: left < 0 ? "over" : "left")
                            .scaleEffect(0.8).frame(width: 160, height: 160)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(p.title, systemImage: p.kind.symbol).font(.title2.bold())
                            if let rule { RuleChip(label: "Notes", rule: rule) }
                        }
                        if !p.blurb.isEmpty { Text(p.blurb).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        if !p.tasks.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(p.tasks.enumerated()), id: \.offset) { i, t in
                                    Button { study.update { $0.toggle(p, i) } } label: {
                                        Label(t, systemImage: run.isChecked(p, i) ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(run.isChecked(p, i) ? .secondary : .primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.top, 2)
                        } else if run.taskBased {
                            Text("No tasks programmed for this period. Add them under Courses, or move on when you're done.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                // Start where you went wrong last time.
                if run.index == 0, let c = course, !c.openMistakes.isEmpty {
                    MistakeList(course: c, title: "Start here: what you got wrong last time")
                }
                if p.kind == .quiz || p.kind == .officeHours {
                    HStack {
                        TextField(p.kind == .quiz ? "Something you got wrong (you'll start there next time)" : "Something to come back to", text: $mistake)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addMistake)
                        Toggle("Also make a flashcard", isOn: $asCard).toggleStyle(.checkbox).disabled(course == nil)
                        Button("Add", action: addMistake).disabled(mistake.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if !run.mistakes.isEmpty {
                        Text("This session: " + run.mistakes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if !run.taskBased {
                        Button("+5 min") { study.update { $0.periodStart += 300 } }
                    }
                    Spacer()
                    let next = run.periods.indices.contains(run.index + 1) ? run.periods[run.index + 1].title : "Wrap up"
                    Button { study.update { $0.nextPeriod() } } label: { Label("Next: \(next)", systemImage: "arrow.right") }
                        .buttonStyle(.borderedProminent)
                        .tint(run.taskBased && !run.periodTasksDone(p) && !p.tasks.isEmpty ? .gray : .accentColor)
                }
            }
        }
    }

    private func addMistake() {
        let t = mistake.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        study.addMistake(t)
        if asCard, let id = run.courseID { store.editCourse(id) { $0.cards.append(Flashcard(front: t, back: "")) } }
        mistake = ""
    }

    @ViewBuilder private func wrapUp(_ course: Course?) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Label("Cycle \(run.cycle) done", systemImage: "flag.checkered").font(.title2.bold())
                Text("Repeat and move on to the next phase if it seems good.").foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button { study.update { $0.repeatCycle(phase: run.phase) } } label: {
                        Label("Repeat \(run.phase.title.lowercased())", systemImage: "arrow.counterclockwise")
                    }
                    if let next = run.phase.next {
                        Button { study.update { $0.repeatCycle(phase: next) } } label: {
                            Label("Move on to \(next.title.lowercased())", systemImage: "arrow.right.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Button("Finish and log") { study.finish() }
                }
                if let c = course {
                    Divider()
                    HStack {
                        TextField("Done with \(c.chapter.isEmpty ? "this chapter" : c.chapter)? Next chapter", text: $newChapter)
                            .textFieldStyle(.roundedBorder)
                        Button("Start it in the reading phase") {
                            let t = newChapter.trimmingCharacters(in: .whitespaces)
                            store.editCourse(c.id) { $0.chapter = t.isEmpty ? $0.chapter : t; $0.phase = .reading }
                            study.update { $0.repeatCycle(phase: .reading); if !t.isEmpty { $0.title = "\(c.title): \(t)" } }
                            newChapter = ""
                        }
                    }
                }
            }
        }
    }
}

/// Things you got wrong, to start with: tick one off once you've got it.
struct MistakeList: View {
    @EnvironmentObject private var store: Store
    let course: Course
    var title = "What you got wrong"

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: "arrow.uturn.backward.circle").font(.callout.weight(.semibold)).foregroundStyle(.orange)
            ForEach(course.openMistakes) { m in
                HStack {
                    Button { store.editCourse(course.id) { c in if let i = c.mistakes.firstIndex(where: { $0.id == m.id }) { c.mistakes[i].resolvedAt = Date() } } } label: {
                        Image(systemName: "circle")
                    }
                    .buttonStyle(.plain).help("Got it now")
                    Text(m.text)
                    Spacer()
                    Text(m.addedAt.formatted(.dateTime.month(.abbreviated).day())).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.08)))
    }
}

// MARK: - Stats and history

private struct StudyStats: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store

    var body: some View {
        let today = store.studyMinutes(on: Date())
        let week = (0..<7).reduce(0) { $0 + store.studyMinutes(on: Date().adding(days: -$1)) }
        HStack(spacing: 12) {
            tile("\(durationString(seconds: today * 60))", "studied today", "clock", .indigo)
            tile("\(durationString(seconds: week * 60))", "in the last 7 days", "calendar", .blue)
            tile("\(store.studyStreak)", store.studyStreak == 1 ? "day streak" : "day streak", "flame", .orange)
            Button { model.screen = .flashcards } label: {
                tile("\(store.dueCardCount)", "flashcards due", "rectangle.on.rectangle.angled", .pink)
            }
            .buttonStyle(.plain)
        }
    }

    private func tile(_ value: String, _ label: String, _ symbol: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol).foregroundStyle(c)
            Text(value).font(.title2.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(c.opacity(0.08)))
    }
}

private struct StudyHistory: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        let logs = store.sortedStudyLogs
        VStack(alignment: .leading, spacing: 14) {
            StudyStats()
            // Minutes per day, last 14 days.
            let days = (0..<14).reversed().map { Date().startOfDay.adding(days: -$0) }
            let mins = days.map { store.studyMinutes(on: $0) }
            let top = max(30, mins.max() ?? 0)
            Card {
                HStack(alignment: .bottom, spacing: 6) {
                    ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                        VStack(spacing: 3) {
                            Text(mins[i] > 0 ? "\(mins[i])" : "").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 3).fill(d.isToday ? Color.accentColor : Color.indigo.opacity(0.6))
                                .frame(height: max(2, CGFloat(mins[i]) / CGFloat(top) * 90))
                            Text(d.formatted(.dateTime.weekday(.narrow))).font(.caption2).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 120)
            }
            SectionTitle(text: "Sessions", symbol: "list.bullet", count: logs.count)
            if logs.isEmpty { Text("Nothing yet. Start a session under Session.").foregroundStyle(.secondary) }
            Card {
                VStack(spacing: 0) {
                    ForEach(Array(logs.prefix(60).enumerated()), id: \.element.id) { i, l in
                        if i > 0 { Divider() }
                        HStack(spacing: 10) {
                            Image(systemName: l.mode.symbol).foregroundStyle(store.course(l.courseID)?.color.color ?? .secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(l.title)
                                Text([l.startedAt.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()), l.mode.title,
                                      l.phase.map { "\($0.title) phase" }, l.note.isEmpty ? nil : l.note].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(durationString(seconds: l.minutes * 60)).monospacedDigit()
                        }
                        .padding(.vertical, 6)
                        .contextMenu { Button("Delete", role: .destructive) { store.studyLogs.removeAll { $0.id == l.id } } }
                    }
                }
            }
        }
    }
}

// MARK: - Courses (all programmable)

private struct CoursesPanel: View {
    @EnvironmentObject private var store: Store
    @AppStorage("studyEditingCourse") private var editingKey = ""

    var body: some View {
        let courses = store.activeCourses
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(courses) { c in
                    Button { editingKey = c.id.uuidString } label: {
                        HStack {
                            RoundedRectangle(cornerRadius: 2).fill(c.color.color).frame(width: 4, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.title).font(.callout.weight(.medium))
                                Text("\(c.phase.title)\(c.chapter.isEmpty ? "" : " · \(c.chapter)")").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(editingKey == c.id.uuidString ? Color.accentColor.opacity(0.15) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button { let c = Course(title: "New course", color: TaskColor.allCases.randomElement() ?? .blue); store.upsert(c); editingKey = c.id.uuidString } label: {
                    Label("New course", systemImage: "plus")
                }
                .padding(.top, 4)
                if courses.isEmpty {
                    Text("A course is a subject you study: Chemistry, CS, History. Each one gets its own class period, tasks and phase.")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
            }
            .frame(width: 220)
            if let id = UUID(uuidString: editingKey), store.course(id) != nil {
                CourseEditor(id: id).id(id)
            } else {
                Text("Pick a course to program it.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
        .onAppear {
            if UUID(uuidString: editingKey).flatMap(store.course) == nil, let first = courses.first { editingKey = first.id.uuidString }
        }
    }
}

private struct CourseEditor: View {
    @EnvironmentObject private var store: Store
    let id: UUID
    @State private var newTask: [UUID: String] = [:]
    @State private var confirmDelete = false

    private var c: Course { store.course(id) ?? Course(title: "") }
    private func edit(_ f: (inout Course) -> Void) { store.editCourse(id, f) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                TextField("Course name", text: Binding(get: { c.title }, set: { v in edit { $0.title = v } }))
                    .textFieldStyle(.plain).font(.title.bold())
                Menu {
                    ForEach(TaskColor.allCases) { col in Button(col.rawValue.capitalized) { edit { $0.color = col } } }
                } label: { Circle().fill(c.color.color).frame(width: 16, height: 16) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Spacer()
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
            TextField("What you're on now (e.g. Ch. 4: Stoichiometry)", text: Binding(get: { c.chapter }, set: { v in edit { $0.chapter = v } }))
                .textFieldStyle(.roundedBorder)

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionTitle(text: "Phase", symbol: "chart.line.uptrend.xyaxis")
                    Picker("", selection: Binding(get: { c.phase }, set: { v in edit { $0.phase = v } })) {
                        ForEach(StudyPhase.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    Text("These overlap a lot with the class periods, so it's guidance: some ideas to try while studying.")
                        .font(.caption).foregroundStyle(.secondary)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                        GridRow {
                            Text("Phase").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text("Homework").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text("Quiz").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        ForEach(StudyPhase.allCases) { p in
                            GridRow {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(p.title).fontWeight(p == c.phase ? .bold : .regular)
                                    Text(p.blurb).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                rulePicker(p, \.homework)
                                rulePicker(p, \.quiz)
                            }
                        }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionTitle(text: "Class period", symbol: "graduationcap")
                        Picker("", selection: Binding(get: { c.taskBased }, set: { v in edit { $0.taskBased = v } })) {
                            Text("Timed").tag(false); Text("By tasks").tag(true)
                        }
                        .pickerStyle(.segmented).fixedSize().labelsHidden()
                    }
                    Text(c.taskBased ? "Each period ends when you've ticked off its tasks." : "Each period ends when its time is up (\(durationString(seconds: c.cycleMinutes * 60)) per cycle). Tasks are a checklist along the way.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(c.periods.enumerated()), id: \.element.id) { i, p in
                        periodRow(i, p)
                        if i < c.periods.count - 1 { Divider() }
                    }
                    HStack {
                        Menu {
                            ForEach(PeriodKind.allCases) { k in
                                Button(k.defaultTitle) { edit { $0.periods.append(StudyPeriod(kind: k)) } }
                            }
                        } label: { Label("Add a period", systemImage: "plus") }
                        .fixedSize()
                        Spacer()
                        Button("Reset to the class period") { edit { $0.periods = StudyPeriod.classPeriod } }.controlSize(.small)
                    }
                }
            }

            if !c.openMistakes.isEmpty { MistakeList(course: c) }
            HStack {
                Label("\(c.cards.count) flashcard\(c.cards.count == 1 ? "" : "s") · \(c.dueCards().count) due", systemImage: "rectangle.on.rectangle.angled")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .confirmationDialog("Delete \(c.title)?", isPresented: $confirmDelete) {
            Button("Archive it (keeps history and cards)") { edit { $0.archived = true } }
            Button("Delete it and its flashcards", role: .destructive) { store.deleteCourse(id) }
        }
    }

    private func rulePicker(_ p: StudyPhase, _ key: WritableKeyPath<PhaseRules, NoteRule>) -> some View {
        Picker("", selection: Binding(get: { c.rules(for: p)[keyPath: key] }, set: { v in
            edit { var r = $0.rules(for: p); r[keyPath: key] = v; $0.rules[p.rawValue] = r }
        })) {
            ForEach(NoteRule.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden().frame(width: 130)
    }

    @ViewBuilder private func periodRow(_ i: Int, _ p: StudyPeriod) -> some View {
        let bind = { (k: WritableKeyPath<StudyPeriod, String>) in
            Binding(get: { c.periods.indices.contains(i) ? c.periods[i][keyPath: k] : "" },
                    set: { v in edit { if $0.periods.indices.contains(i) { $0.periods[i][keyPath: k] = v } } })
        }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { p.enabled }, set: { v in edit { $0.periods[i].enabled = v } })).labelsHidden()
                Image(systemName: p.kind.symbol).foregroundStyle(.secondary).frame(width: 18)
                TextField("Period name", text: bind(\.title)).textFieldStyle(.plain).font(.body.weight(.medium))
                if !c.taskBased {
                    Stepper("\(p.minutes) min", value: Binding(get: { p.minutes }, set: { v in edit { $0.periods[i].minutes = v } }), in: 1...240, step: 5)
                        .fixedSize()
                }
                Button { edit { $0.periods.swapAt(i, i - 1) } } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).disabled(i == 0)
                Button { edit { $0.periods.swapAt(i, i + 1) } } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless).disabled(i == c.periods.count - 1)
                Button { edit { $0.periods.remove(at: i) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).foregroundStyle(.red)
            }
            .opacity(p.enabled ? 1 : 0.5)
            TextField("What to do in this period", text: bind(\.blurb), axis: .vertical)
                .textFieldStyle(.plain).font(.caption).foregroundStyle(.secondary).padding(.leading, 52)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(p.tasks.enumerated()), id: \.offset) { ti, t in
                    HStack {
                        Image(systemName: "square").font(.caption).foregroundStyle(.secondary)
                        Text(t).font(.callout)
                        Spacer()
                        Button { edit { $0.periods[i].tasks.remove(at: ti) } } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).font(.caption)
                    }
                }
                HStack {
                    Image(systemName: "plus").font(.caption).foregroundStyle(.secondary)
                    TextField("Add a task for this period", text: Binding(get: { newTask[p.id] ?? "" }, set: { newTask[p.id] = $0 }))
                        .textFieldStyle(.plain).font(.callout)
                        .onSubmit {
                            let t = (newTask[p.id] ?? "").trimmingCharacters(in: .whitespaces)
                            guard !t.isEmpty else { return }
                            edit { $0.periods[i].tasks.append(t) }
                            newTask[p.id] = ""
                        }
                }
            }
            .padding(.leading, 52)
        }
        .padding(.vertical, 4)
    }
}
