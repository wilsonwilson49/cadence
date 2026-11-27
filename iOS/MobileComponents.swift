import SwiftUI

// MARK: - Checklist row

/// A checklist item: the round check (with a reflection) and the square X ("didn't do it").
struct MobileRow: View {
    @EnvironmentObject private var model: MobileModel
    let occ: Occurrence
    var showDate = false
    /// In a list already grouped by day (Week), don't repeat the date on every row.
    var inDayList = false
    @State private var confirmDelete = false

    var body: some View {
        let t = occ.task
        HStack(spacing: 12) {
            Button { model.toggle(occ) } label: {
                Image(systemName: occ.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24)).foregroundStyle(occ.isDone ? t.color.color : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(occ.isDone ? "Mark as not done" : "Check off")
            if t.isBonus {
                Image(systemName: "star.fill").font(.system(size: 13)).foregroundStyle(.yellow).frame(width: 20, height: 20)
                    .accessibilityLabel("Bonus task")
            } else {
            Button { model.toggleMissed(occ) } label: {
                RoundedRectangle(cornerRadius: 5)
                    .fill(occ.isMissed ? Color.red : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(occ.isMissed ? Color.red : Color.secondary.opacity(0.6), lineWidth: 1.5))
                    .overlay(Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(occ.isMissed ? .white : .clear))
                    .frame(width: 20, height: 20)
                    .opacity(occ.isDone ? 0.35 : 1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(occ.isMissed ? "Undo didn't do it" : "Didn't do it")
            }
            RoundedRectangle(cornerRadius: 2).fill(t.color.color).frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(t.title)
                    .strikethrough(occ.isResolved, color: occ.isMissed ? .red : nil)
                    .foregroundStyle(occ.isResolved ? .secondary : .primary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if occ.isMissed { Text("Didn't do it").foregroundStyle(.red).fontWeight(.semibold) }
                    if showDate || (occ.isOverdue && !inDayList) {
                        Text(occ.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())).foregroundStyle(occ.isOverdue ? .red : .secondary)
                    }
                    if t.isBonus {
                        let today = t.bonusKeys(on: occ.day).count
                        Label("Bonus · \(t.bonusSummary(on: occ.day))\(today > 0 && !occ.isDone && today != t.bonusRoundKeys(on: occ.day).count ? " · \(today)× today" : "")", systemImage: "star").lineLimit(1)
                    }
                    if let s = occ.start { Label(timeString(s), systemImage: "clock") }
                    if occ.isUntilDone && !occ.isResolved { Label(t.carryLabel(on: occ.day), systemImage: "flame").lineLimit(1) }
                    else if let p = t.isBonus ? t.bonusRepeatSummary : t.planSummary { Label(p, systemImage: "repeat").lineLimit(1) }
                    if let p = t.priorityLevel, !occ.isResolved {
                        Image(systemName: p.symbol).foregroundStyle(p.color).accessibilityLabel("\(p.title) priority")
                    }
                    if let h = t.hardnessLevel { HardnessMeter(level: h, height: 9) }
                    if occ.isDone, let m = t.timeTaken?[occ.key] { Label(TaskStats.format(m), systemImage: "stopwatch") }
                    else if !occ.isResolved, let m = t.typicalMinutes { Label("~\(TaskStats.format(m))", systemImage: "stopwatch").accessibilityLabel("usually \(TaskStats.format(m))") }
                    if t.isPastDue { Text("Past due").foregroundStyle(.red) }
                    if t.isUrgent && t.isUntilDone && !occ.isResolved { Text("URGENT").font(.system(size: 9, weight: .heavy)).foregroundStyle(.red) }
                    if t.hasSteps {
                        let p = t.stepProgress(for: occ)
                        Label("\(p.done)/\(p.total)", systemImage: "checklist").foregroundStyle(p.done == p.total ? .green : .secondary)
                    }
                }
                .font(.app(.caption)).foregroundStyle(.secondary).labelStyle(TightLabel())
                if t.hasSteps && !inDayList { MobileStepList(occ: occ).padding(.top, 4) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { model.editing = model.store.task(t.id) ?? t }
        .swipeActions(edge: .trailing) {
            if t.recurrence.isRepeating && !t.isUntilDone {
                Button("Skip") { model.store.skip(occ) }.tint(.orange)
            }
            Button("Delete", role: .destructive) { confirmDelete = true }
            if t.isUntilDone && !occ.isResolved {
                Button(t.isUrgent ? "Not urgent" : "Urgent") { model.store.setUrgent(t.id, !t.isUrgent) }.tint(.orange)
            }
            Button("Edit") { model.editing = model.store.task(t.id) ?? t }.tint(.blue)
        }
        .confirmationDialog("Delete “\(t.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            if t.recurrence.isRepeating {
                let day = (t.isUntilDone ? t.currentRepStart(on: occ.day) : nil) ?? occ.day
                Button("Only this one (\(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())))") { model.store.delete(occ, scope: .one) }
                Button("This one and all later ones") { model.store.delete(occ, scope: .fromHere) }
                Button("All of them, past and future", role: .destructive) { model.store.delete(occ, scope: .all) }
            } else {
                Button("Delete", role: .destructive) { model.store.delete(occ, scope: .all) }
            }
        } message: {
            Text(t.recurrence.isRepeating ? "It repeats. Reflections you wrote are kept either way." : "Reflections you wrote are kept.")
        }
    }
}

struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon.imageScale(.small); configuration.title }
    }
}

/// An event in the day's schedule (no checkbox).
struct MobileEventRow: View {
    @EnvironmentObject private var model: MobileModel
    let occ: Occurrence
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(occ.start.map(timeString) ?? "All day").font(.app(.callout).monospacedDigit())
                if let e = occ.end { Text(timeString(e)).font(.app(.caption)).foregroundStyle(.secondary) }
            }
            .frame(width: 64, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(occ.task.color.color).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(occ.task.title).lineLimit(1)
                Text(occ.task.source == "google" ? "Google Calendar" : occ.task.source == "calendly" ? "Calendly" : "Event")
                    .font(.app(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { model.editing = model.store.task(occ.task.id) ?? occ.task }
    }
}

// MARK: - Progress ring

struct Ring: View {
    let done: Int
    let total: Int
    var size: CGFloat = 64
    var line: CGFloat = 8
    /// Show what's left: starts full, empties as things get checked off.
    var showsLeft = false
    var body: some View {
        let left = max(0, total - done)
        let frac = total == 0 ? 0 : Double(showsLeft ? left : done) / Double(total)
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: line)
            Circle().trim(from: 0, to: frac)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.6), value: frac)
            if showsLeft && total > 0 && left == 0 {
                Image(systemName: "checkmark").font(.system(size: size * 0.34, weight: .bold)).foregroundStyle(.green)
            } else if showsLeft && total > 0 {
                VStack(spacing: -2) {
                    Text("\(left)").font(.system(size: size * 0.3, weight: .bold).monospacedDigit())
                    Text("left").font(.system(size: size * 0.13, weight: .medium)).foregroundStyle(.secondary)
                }
            } else {
                Text("\(done)/\(total)").font(.system(size: size * 0.24, weight: .bold).monospacedDigit())
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Reflection

/// Every check-off (and every "didn't do it") needs a short reflection: same rule as the Mac and web.
struct ReflectionSheet: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let target: ReflectTarget
    @State private var text = ""
    @State private var taken = ""
    @FocusState private var focused: Bool

    private static let prompts = ["What went well, and why?", "What got in the way or felt harder than expected?",
                                  "What will you do differently next time?", "How did this move you toward a bigger goal?",
                                  "What did you learn about how you work?"]
    private static let missedPrompts = ["What got in the way?", "Was it in your control, or not?", "What would make it happen next time?",
                                        "Was it still the right thing to plan, or should it change?", "How do you feel about skipping it?"]

    var body: some View {
        let min = store.settings.minReflectionWords
        let count = countWords(text)
        let pool = target.missed ? Self.missedPrompts : Self.prompts
        let seed = abs(target.occ.task.id.hashValue ^ target.occ.key.hashValue)
        NavigationStack {
            // Scrolls so nothing is cut off on smaller iPhones with the keyboard up.
            ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: target.missed ? "xmark" : "text.quote").font(.app(.headline)).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(target.missed ? Color.red : target.occ.task.color.color))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.occ.task.title).font(.app(.headline)).lineLimit(2)
                        Text(target.occ.day.formatted(.dateTime.weekday(.wide).month().day())).font(.app(.caption)).foregroundStyle(.secondary)
                    }
                }
                Text(target.missed ? "Write at least \(min) words about why you didn't or couldn't do it. It is marked as not done rather than failed, and the reflection is for learning what got in the way."
                                   : "Write at least \(min) words before checking this off.")
                    .font(.app(.callout))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        Label(pool[(seed + i) % pool.count], systemImage: "circle.fill").labelStyle(BulletLabel())
                            .font(.app(.callout)).foregroundStyle(.secondary)
                    }
                }
                TextEditor(text: $text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                    .frame(height: 180)
                if !target.missed {
                    TimeTakenField(task: target.occ.task, text: $taken).font(.app(.callout))
                }
                HStack {
                    ProgressView(value: Double(Swift.min(count, min)), total: Double(min)).tint(count >= min ? .green : Theme.accent)
                    Text("\(count) / \(min) words").font(.app(.caption).monospacedDigit()).foregroundStyle(count >= min ? .green : .secondary)
                }
            }
            .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(target.missed ? "Why didn't it happen?" : "Reflect to complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(target.missed ? "Not done" : "Complete") {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if target.missed { store.miss(target.occ, reflection: t) }
                        else { store.complete(target.occ, reflection: t, minutes: TaskStats.parseMinutes(taken)) }
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(count < min || (!target.missed && !TimeTakenField.isValid(taken)))
                }
            }
            .onAppear { focused = true }
        }
    }
}

struct BulletLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) { configuration.icon.font(.system(size: 4)); configuration.title }
    }
}

// MARK: - Editor

/// A habit's steps for one occurrence: tap to tick; ticking the last one opens the check-off.
struct MobileStepList: View {
    @EnvironmentObject private var model: MobileModel
    @EnvironmentObject private var store: Store
    let occ: Occurrence

    var body: some View {
        let t = store.task(occ.task.id) ?? occ.task
        let o = Occurrence(task: t, day: occ.day)
        let done = t.stepsDone(for: o)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(t.habitSteps) { s in
                let on = done.contains(s.id)
                Button { if store.toggleStep(o, s.id) { model.reflect(Occurrence(task: store.task(t.id) ?? t, day: o.day)) } } label: {
                    HStack(spacing: 8) {
                        Image(systemName: on ? "checkmark.square.fill" : "square").foregroundStyle(on ? t.color.color : .secondary)
                        Text(s.title).strikethrough(on).foregroundStyle(on ? .secondary : .primary)
                    }
                    .font(.app(.subheadline))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(o.isResolved)
            }
        }
    }
}

/// Make or change a task, habit or event (the most-used options; everything else is kept as it is).
struct EditorSheet: View {
    @EnvironmentObject private var model: MobileModel
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State var task: PlanTask
    @State private var hasTime: Bool
    @State private var time: Date
    @State private var hasDue: Bool
    @State private var due: Date
    @State private var confirmDelete = false
    @State private var newStep = ""
    private let isNew: Bool

    init(task: PlanTask, isNew: Bool) {
        _task = State(initialValue: task)
        _hasTime = State(initialValue: task.timeMinutes != nil)
        _time = State(initialValue: dayAt(task.startDate, minutes: task.timeMinutes ?? 9 * 60))
        _hasDue = State(initialValue: task.dueDate != nil)
        _due = State(initialValue: task.dueDate ?? task.startDate.adding(days: 3))
        self.isNew = isNew
    }

    private var kind: String { task.isEvent ? "event" : task.isBonus ? "bonus" : task.isHabit ? "habit" : "task" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: Binding(get: { kind }, set: setKind)) {
                        Text("Task").tag("task"); Text("Habit").tag("habit"); Text("Event").tag("event"); Text("Bonus").tag("bonus")
                    }
                    .pickerStyle(.segmented)
                    TextField("Title", text: $task.title)
                    TextField("Notes", text: $task.notes, axis: .vertical).lineLimit(1...4)
                } footer: {
                    Text(task.isEvent ? "Events appear on the calendar only. They have no checkbox and no reflection."
                         : task.isBonus ? "Bonus tasks are optional. They are listed on Today but are never overdue and never send reminders. Each one finished during a focus session gives +\(Bonus.points) points."
                         : task.isHabit ? "Habits repeat on a schedule and are tracked on the Habits tab, which shows their streaks."
                         : "Tasks go on your checklist, and checking one off asks for a short reflection.")
                }
                if !task.isEvent {
                    Section("Priority and hardness") {
                        Picker("Priority", selection: $task.priority) {
                            Text("None").tag(String?.none)
                            ForEach(Priority.allCases) { p in Text(p.title).tag(String?.some(p.rawValue)) }
                        }
                        .pickerStyle(.segmented)
                        HStack { Text("Hardness"); Spacer(); HardnessPicker(value: $task.hardness, barHeight: 24) }
                    }
                    Section {
                        Toggle(isOn: Binding(get: { task.offComputer == true }, set: { task.offComputer = $0 ? true : nil })) {
                            Label("Done away from the computer", systemImage: "figure.walk")
                        }
                    } footer: {
                        Text(task.offComputer == true
                             ? "A focus session on this task, on the Mac or the web, keeps running while you are away from the computer."
                             : "A focus session on this task, on the Mac or the web, pauses after 5 minutes without input.")
                    }
                }
                if task.isBonus {
                    let limit = task.bonusLimit ?? 1
                    Section {
                        DatePicker("On your list from", selection: $task.startDate, displayedComponents: .date)
                        Picker(task.cycleGapDays != nil || task.recurrence.isRepeating ? "Each time, up to" : "Can be checked off", selection: Binding(get: { limit }, set: {
                            task.bonusLimit = $0 == 1 ? nil : $0
                            if $0 <= 0 { task.cycleGapDays = nil; task.cycleTimes = nil }
                        })) {
                            ForEach(Array(Set(Bonus.limitChoices + [limit])).sorted { ($0 <= 0 ? Int.max : $0) < ($1 <= 0 ? Int.max : $1) }, id: \.self) { n in
                                Text(Bonus.limitLabel(n)).tag(n)
                            }
                        }
                        if limit > 0 {
                            Stepper("Exactly \(limit) time\(limit == 1 ? "" : "s")", value: Binding(get: { limit }, set: { task.bonusLimit = $0 == 1 ? nil : $0 }), in: 1...999)
                        }
                        if let saved = model.store.task(task.id), saved.bonusCount > 0 {
                            LabeledContent("So far", value: "\(saved.bonusCount) time\(saved.bonusCount == 1 ? "" : "s")\(saved.bonusFinished ? ", all done" : "")")
                        }
                    } header: { Text("Bonus") } footer: {
                        Text(limit <= 0 ? "No limit: check it off as often as you like." : limit == 1 ? "Check it off once each time it comes around." : "It stays on your list until you've checked it off \(limit) times, each time it comes around.")
                    }
                    Section {
                        Picker("Comes back", selection: Binding(get: { task.cycleGapDays != nil ? "cycle" : task.recurrence.frequency.rawValue }, set: { v in
                            if v == "cycle" { task.recurrence = Recurrence(); task.cycleGapDays = task.cycleGapDays ?? 7; task.cycleTimes = task.cycleTimes ?? 3 }
                            else { task.cycleGapDays = nil; task.cycleTimes = nil; task.recurrence.frequency = Frequency(rawValue: v) ?? .none }
                        })) {
                            Text("No, just once").tag(Frequency.none.rawValue)
                            ForEach(Frequency.allCases.filter { $0 != .none }) { Text($0.label).tag($0.rawValue) }
                            if limit > 0 { Text("After it's done, with a break").tag("cycle") }
                        }
                        if task.cycleGapDays != nil {
                            Stepper("Break: \(task.cycleGapDays ?? 7) day\(task.cycleGapDays == 1 ? "" : "s")", value: Binding(get: { task.cycleGapDays ?? 7 }, set: { task.cycleGapDays = $0 }), in: 1...365)
                            Stepper("Times in total: \(task.cycleTimes ?? 3)", value: Binding(get: { task.cycleTimes ?? 3 }, set: { task.cycleTimes = $0 }), in: 1...99)
                        } else if task.recurrence.isRepeating {
                            Stepper(task.recurrence.interval == 1 ? "Every \(task.recurrence.frequency.unit)" : "Every \(task.recurrence.interval) \(task.recurrence.frequency.unit)s",
                                    value: $task.recurrence.interval, in: 1...99)
                            if task.recurrence.frequency == .weekly {
                                WeekdayChips(selection: $task.recurrence.weekdays, start: task.startDate)
                            }
                        }
                    } header: { Text("Comes back") } footer: {
                        if task.recurrence.isRepeating { Text("Each time it comes around the count starts again, and unused check-offs do not carry over.") }
                        else if task.cycleGapDays != nil { Text("After it has been checked off, it takes a break and then comes back.") }
                    }
                }
                if !task.isBonus {
                Section("When") {
                    if !task.isEvent && !task.isHabit {
                        Picker("Starts", selection: Binding(get: { task.after != nil }, set: { on in
                            if on { task.after = model.store.possibleTriggers(for: task.id).first?.id }
                            else { task.after = nil; task.afterMinutes = nil; task.armedAt = nil; task.armedBy = nil }
                        })) { Text("On a date").tag(false); Text("After a task").tag(true) }
                        .pickerStyle(.segmented)
                    }
                    if task.after != nil {
                        Picker("After", selection: $task.after) {
                            ForEach(model.store.possibleTriggers(for: task.id)) { t in Text(t.title).tag(Optional(t.id)) }
                        }
                        Picker("Comes up", selection: Binding(get: { task.afterMinutes ?? 0 }, set: { task.afterMinutes = $0 == 0 ? nil : $0 })) {
                            ForEach(PlanTask.afterChoices, id: \.self) { m in Text(PlanTask.afterLabel(m)).tag(m) }
                        }
                    } else {
                    DatePicker(task.isHabit ? "Starts" : "Date", selection: $task.startDate, displayedComponents: .date)
                    Toggle("At a specific time", isOn: $hasTime)
                    }
                    if hasTime && task.after == nil {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        Picker("Length", selection: $task.durationMinutes) {
                            ForEach(Array(Set([5, 10, 15, 30, 45, 60, 90, 120, 180, task.durationMinutes])).sorted(), id: \.self) { m in
                                Text(m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) hr" : "\(m / 60) hr \(m % 60) min").tag(m)
                            }
                        }
                    }
                }
                }
                if task.isHabit || task.isEvent {
                    Section("Repeat") {
                        Picker("Repeats", selection: $task.recurrence.frequency) {
                            ForEach(Frequency.allCases.filter { task.isHabit ? $0 != .none : true }) { Text($0.label).tag($0) }
                        }
                        if task.recurrence.frequency == .weekly {
                            WeekdayChips(selection: $task.recurrence.weekdays, start: task.startDate)
                        }
                    }
                }
                if !task.isEvent && !task.isBonus && !task.isLongTerm && !task.isCycle {
                    Section {
                        Toggle(isOn: Binding(get: { task.isUntilDone }, set: { task.mode = $0 ? "untilDone" : nil })) {
                            Label("Keep it on my list until it's done", systemImage: "flame")
                        }
                        if task.isUntilDone && !task.recurrence.isRepeating {
                            Toggle("Has a due date", isOn: $hasDue)
                            if hasDue { DatePicker("Due by", selection: $due, in: task.startDate..., displayedComponents: .date) }
                        }
                    } footer: {
                        if task.isUntilDone {
                            Text(task.recurrence.isRepeating ? "Each one stays on your list until you finish it, or until the next one replaces it."
                                 : "It appears every day until you check it off or mark it “didn't do it”.")
                        }
                    }
                }
                if task.isHabit { stepsSection; habitSection }
                if !task.isBonus {
                Section("Reminders") {
                    Toggle("Notify me", isOn: Binding(get: { !task.channels.isEmpty }, set: { task.channels = $0 ? store.settings.defaultChannels : [] }))
                    if !task.channels.isEmpty {
                        ForEach([0, 5, 10, 15, 30, 60], id: \.self) { off in
                            Toggle(offsetString(off), isOn: Binding(get: { task.reminderOffsets.contains(off) }, set: { on in
                                if on { task.reminderOffsets.insert(off) } else { task.reminderOffsets.remove(off) }
                            }))
                        }
                    }
                }
                }
                if !task.isEvent && !task.isBonus {
                    Section {
                        Picker("Keep after me", selection: Binding(get: { task.nagLevel }, set: { task.nag = $0 == .normal ? nil : $0.rawValue })) {
                            ForEach(NagLevel.allCases) { Text($0.title).tag($0) }
                        }
                        if task.nagLevel != .normal {
                            Picker("Comes back every", selection: Binding(get: { task.nagMinutes }, set: { task.nagEvery = $0 == 10 ? nil : $0 })) {
                                ForEach(NagLevel.everyChoices, id: \.self) { m in Text(m == 60 ? "hour" : "\(m) min").tag(m) }
                            }
                        }
                    } header: { Text("For things you'd rather put off") } footer: {
                        Text(task.nagLevel == .normal ? task.nagLevel.detail
                             : "On iPhone this is a notification that keeps coming back. The windows and app blocking only happen on the Mac and the web.")
                    }
                }
                if !task.isEvent { timeTakenSection }
                Section("Color") {
                    HStack {
                        ForEach(TaskColor.allCases) { c in
                            Circle().fill(c.color).frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(.white, lineWidth: task.color == c ? 3 : 0))
                                .onTapGesture { task.color = c }
                        }
                    }
                }
                if !isNew {
                    Section {
                        Button(task.isImported ? "Hide" : "Delete", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle("\(isNew ? "New" : "Edit") \(task.isBonus ? "Bonus Task" : kind.capitalized)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save", action: save).fontWeight(.semibold)
                        .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete “\(task.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(task.isImported ? "Hide" : "Delete", role: .destructive) { store.delete(taskID: task.id); dismiss() }
            } message: {
                Text(task.isImported ? "It'll stay in the original calendar." : "Reflections you've written for it are kept.")
            }
        }
    }

    private func setKind(_ k: String) {
        let wasBonus = task.isBonus
        task.kind = k
        if k == "bonus" {
            task.mode = nil; task.habit = nil; hasTime = false
            task.after = nil; task.afterMinutes = nil; task.armedAt = nil; task.armedBy = nil
            task.channels = []; task.nag = nil; task.busy = false
            if isNew && task.color == .blue { task.color = .yellow }
        } else if wasBonus {
            task.channels = store.settings.defaultChannels
        }
        if k == "event" { task.mode = nil; if !hasTime { hasTime = true }; task.busy = true }
        if k == "habit" {
            if !task.recurrence.isRepeating { task.recurrence.frequency = .daily }
            if task.isCycle { task.mode = nil; task.cycleGapDays = nil; task.cycleTimes = nil }
            if task.habit == nil { task.habit = HabitInfo() }
            task.busy = false
        }
        if k == "task" {
            if task.recurrence.isRepeating { task.recurrence = Recurrence() }
            if task.isLongTerm { task.mode = nil }
            task.busy = false
        }
    }

    private func habitText(_ key: WritableKeyPath<HabitInfo, String?>) -> Binding<String> {
        Binding(get: { task.habit?[keyPath: key] ?? "" }, set: { v in var h = task.habit ?? HabitInfo(); h[keyPath: key] = v.isEmpty ? nil : v; task.habit = h })
    }

    /// Steps: a small checklist that starts fresh each time the habit comes around.
    /// How long it really took each time, and how long it usually takes (a weighted average).
    @ViewBuilder private var timeTakenSection: some View {
        let entries = (task.timeTaken ?? [:]).sorted { $0.key > $1.key }
        Section {
            if entries.isEmpty {
                Text("Not timed yet. When you check it off, you can write down how long it took, and this shows how long it usually takes.")
                    .font(.app(.caption)).foregroundStyle(.secondary)
            } else {
                TimeSpread(task: task).padding(.vertical, 4)
                if let line = TaskStatsText.typical(task) { Text(line).font(.app(.caption)).foregroundStyle(.secondary) }
                if let typical = task.typicalMinutes, typical != task.durationMinutes {
                    Button("Plan \(TaskStats.format(typical)) for it") { task.durationMinutes = typical }
                }
                ForEach(entries.prefix(8), id: \.key) { e in
                    HStack {
                        Text(DateKey.date(e.key)?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? e.key)
                        Spacer()
                        Text(TaskStats.format(e.value)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            task.timeTaken?[e.key] = nil
                            if task.timeTaken?.isEmpty == true { task.timeTaken = nil }
                        }
                    }
                }
            }
        } header: { Text("Time it took") } footer: {
            if entries.count > 8 { Text("Showing the latest 8 of \(entries.count). Swipe one to remove it.") }
            else if !entries.isEmpty { Text("Swipe a time to remove it.") }
        }
    }

    @ViewBuilder private var stepsSection: some View {
        Section {
            ForEach(Array(task.habitSteps.enumerated()), id: \.element.id) { i, _ in
                TextField("Step \(i + 1)", text: Binding(get: { task.habitSteps.indices.contains(i) ? task.habitSteps[i].title : "" },
                                                        set: { v in if task.steps?.indices.contains(i) == true { task.steps?[i].title = v } }))
            }
            .onDelete { task.steps?.remove(atOffsets: $0); if task.steps?.isEmpty == true { task.steps = nil } }
            .onMove { task.steps?.move(fromOffsets: $0, toOffset: $1) }
            HStack {
                Image(systemName: "plus.circle.fill").foregroundStyle(task.color.color)
                TextField("Add a step", text: $newStep).submitLabel(.done).onSubmit(addStep)
            }
        } header: { Text("Steps") } footer: {
            Text("Optional. Steps are ticked off each time and start unticked the next time the habit comes around. Ticking the last step opens the check-off. Swipe a step to delete it.")
        }
    }

    private func addStep() {
        let t = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        task.steps = task.habitSteps + [HabitStep(title: t)]
        newStep = ""
    }

    @ViewBuilder private var habitSection: some View {
        let style = task.habit?.style ?? "build"
        Section {
            Picker("Style", selection: Binding(get: { style }, set: { v in var h = task.habit ?? HabitInfo(); h.style = v; task.habit = h })) {
                ForEach(HabitInfo.styles, id: \.id) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.segmented)
            if style == "stack" { TextField("After I… (pour my morning coffee)", text: habitText(\.stackAfter)) }
            if style == "replace" { TextField("Instead of… (scrolling in bed)", text: habitText(\.replaces)) }
            TextField("I am someone who… (reads every day)", text: habitText(\.identity))
            TextField("When and where (at 9 PM on the couch)", text: habitText(\.cue))
            TextField("2-minute version (read one page)", text: habitText(\.twoMinute))
            TextField("Right after, I get… (a cup of tea)", text: habitText(\.reward))
            if let s = task.habitSentence { Label(s, systemImage: "quote.opening").font(.app(.callout)).italic().foregroundStyle(.green) }
        } header: {
            Text("Make it stick")
        }
    }

    private func save() {
        var t = task
        t.title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
        t.startDate = t.startDate.startOfDay
        t.timeMinutes = hasTime ? time.minutesSinceMidnight : nil
        if t.after != nil {
            // A follow-up keeps the date and time it was set off at (or none yet); it has no schedule of its own.
            t.timeMinutes = task.armedAt == nil ? nil : task.timeMinutes
            t.recurrence = Recurrence()
            if model.store.task(t.id)?.after != t.after { t.armedAt = nil; t.armedBy = nil }
        }
        if t.recurrence.frequency != .weekly { t.recurrence.weekdays = [] }
        else if t.recurrence.weekdays.isEmpty { t.recurrence.weekdays = [Calendar.current.component(.weekday, from: t.startDate)] }
        if t.reminderOffsets.isEmpty { t.reminderOffsets = [0] }
        if t.isEvent { t.mode = nil }
        t.dueDate = t.isUntilDone && !t.isCycle && !t.recurrence.isRepeating && hasDue ? due.startOfDay : nil
        let pending = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty { t.steps = t.habitSteps + [HabitStep(title: pending)] }
        let steps = t.habitSteps.map { var s = $0; s.title = s.title.trimmingCharacters(in: .whitespacesAndNewlines); return s }.filter { !$0.title.isEmpty }
        t.steps = t.isHabit && !steps.isEmpty ? steps : nil
        if t.steps == nil { t.stepsDone = nil }
        if t.isHabit {
            t.kind = "habit"
            var h = t.habit ?? HabitInfo()
            for k in [\HabitInfo.identity, \.cue, \.stackAfter, \.replaces, \.twoMinute, \.reward] {
                let v = h[keyPath: k]?.trimmingCharacters(in: .whitespacesAndNewlines)
                h[keyPath: k] = v?.isEmpty == false ? v : nil
            }
            t.habit = h
        } else { t.habit = nil }
        if t.isBonus {
            t.timeMinutes = nil; t.mode = nil; t.dueDate = nil; t.urgent = nil
            if t.cycleGapDays != nil && t.bonusMax != nil { t.recurrence = Recurrence(); t.cycleTimes = t.cycleTimes ?? 3 }
            else { t.cycleGapDays = nil; t.cycleTimes = nil }
            t.after = nil; t.afterMinutes = nil; t.armedAt = nil; t.armedBy = nil
            t.channels = []; t.nag = nil; t.nagEvery = nil; t.busy = false
        } else { t.bonusLimit = nil }
        store.upsert(t)
        dismiss()
    }
}

struct WeekdayChips: View {
    @Binding var selection: [Int]
    let start: Date
    var body: some View {
        let cal = Calendar.current
        let current = selection.isEmpty ? [cal.component(.weekday, from: start)] : selection
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { wd in
                let on = current.contains(wd)
                Text(cal.veryShortWeekdaySymbols[wd - 1]).font(.app(.callout).weight(.semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(on ? .white : .primary)
                    .background(Circle().fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
                    .onTapGesture {
                        var s = current
                        if on { if s.count > 1 { s.removeAll { $0 == wd } } } else { s.append(wd); s.sort() }
                        selection = s
                    }
            }
        }
        .frame(maxWidth: .infinity)
    }
}
