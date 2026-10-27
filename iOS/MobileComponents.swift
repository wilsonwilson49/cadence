import SwiftUI

// MARK: - Checklist row

/// A checklist item: the round check (with a reflection) and the square X ("didn't do it").
struct MobileRow: View {
    @EnvironmentObject private var model: MobileModel
    let occ: Occurrence
    var showDate = false
    /// In a list already grouped by day (Week), don't repeat the date on every row.
    var inDayList = false

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
                    if let s = occ.start { Label(timeString(s), systemImage: "clock") }
                    if occ.isUntilDone && !occ.isResolved { Label(t.carryLabel(on: occ.day), systemImage: "flame").lineLimit(1) }
                    else if let p = t.planSummary { Label(p, systemImage: "repeat").lineLimit(1) }
                    if t.isPastDue { Text("Past due").foregroundStyle(.red) }
                }
                .font(.caption).foregroundStyle(.secondary).labelStyle(TightLabel())
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
            Button("Edit") { model.editing = model.store.task(t.id) ?? t }.tint(.blue)
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
                Text(occ.start.map(timeString) ?? "All day").font(.callout.monospacedDigit())
                if let e = occ.end { Text(timeString(e)).font(.caption).foregroundStyle(.secondary) }
            }
            .frame(width: 64, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(occ.task.color.color).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(occ.task.title).lineLimit(1)
                Text(occ.task.source == "google" ? "Google Calendar" : occ.task.source == "calendly" ? "Calendly" : "Event")
                    .font(.caption).foregroundStyle(.secondary)
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
    var body: some View {
        let frac = total == 0 ? 0 : Double(done) / Double(total)
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: line)
            Circle().trim(from: 0, to: frac)
                .stroke(AngularGradient(colors: [.orange, .pink, .purple], center: .center), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(duration: 0.6), value: frac)
            Text("\(done)/\(total)").font(.system(size: size * 0.24, weight: .bold).monospacedDigit())
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
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: target.missed ? "xmark" : "text.quote").font(.headline).foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(target.missed ? Color.red : target.occ.task.color.color))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.occ.task.title).font(.headline).lineLimit(2)
                        Text(target.occ.day.formatted(.dateTime.weekday(.wide).month().day())).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(target.missed ? "Write at least \(min) words about why you didn't or couldn't do it. It's marked as not done, not failed: this is for learning."
                                   : "Write at least \(min) words before checking this off.")
                    .font(.callout)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        Label(pool[(seed + i) % pool.count], systemImage: "circle.fill").labelStyle(BulletLabel())
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                TextEditor(text: $text)
                    .focused($focused)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                    .frame(minHeight: 160)
                HStack {
                    ProgressView(value: Double(Swift.min(count, min)), total: Double(min)).tint(count >= min ? .green : .pink)
                    Text("\(count) / \(min) words").font(.caption.monospacedDigit()).foregroundStyle(count >= min ? .green : .secondary)
                }
                Spacer()
            }
            .padding()
            .navigationTitle(target.missed ? "Why didn't it happen?" : "Reflect to complete")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(target.missed ? "Not done" : "Complete") {
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if target.missed { store.miss(target.occ, reflection: t) } else { store.complete(target.occ, reflection: t) }
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(count < min)
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
    private let isNew: Bool

    init(task: PlanTask, isNew: Bool) {
        _task = State(initialValue: task)
        _hasTime = State(initialValue: task.timeMinutes != nil)
        _time = State(initialValue: dayAt(task.startDate, minutes: task.timeMinutes ?? 9 * 60))
        _hasDue = State(initialValue: task.dueDate != nil)
        _due = State(initialValue: task.dueDate ?? task.startDate.adding(days: 3))
        self.isNew = isNew
    }

    private var kind: String { task.isEvent ? "event" : task.isHabit ? "habit" : "task" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Kind", selection: Binding(get: { kind }, set: setKind)) {
                        Text("Task").tag("task"); Text("Habit").tag("habit"); Text("Event").tag("event")
                    }
                    .pickerStyle(.segmented)
                    TextField("Title", text: $task.title)
                    TextField("Notes", text: $task.notes, axis: .vertical).lineLimit(1...4)
                } footer: {
                    Text(task.isEvent ? "Events show on your calendar only: no checkbox, no reflection."
                         : task.isHabit ? "Habits repeat and are tracked on the Habits tab: streaks, and never missing twice."
                         : "Tasks go on your checklist; checking one off asks for a short reflection.")
                }
                Section("When") {
                    DatePicker(task.isHabit ? "Starts" : "Date", selection: $task.startDate, displayedComponents: .date)
                    Toggle("At a specific time", isOn: $hasTime)
                    if hasTime {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        Picker("Length", selection: $task.durationMinutes) {
                            ForEach([5, 10, 15, 30, 45, 60, 90, 120, 180], id: \.self) { m in
                                Text(m < 60 ? "\(m) min" : m % 60 == 0 ? "\(m / 60) hr" : "\(m / 60) hr \(m % 60) min").tag(m)
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
                if !task.isEvent && !task.isLongTerm && !task.isCycle {
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
                            Text(task.recurrence.isRepeating ? "Each one stays on your list until you finish it, or until the next one arrives."
                                 : "It shows up every day until you check it off or mark it “didn't do it”.")
                        }
                    }
                }
                if task.isHabit { habitSection }
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
            .navigationTitle("\(isNew ? "New" : "Edit") \(kind.capitalized)")
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
        task.kind = k
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
            if let s = task.habitSentence { Label(s, systemImage: "quote.opening").font(.callout).italic().foregroundStyle(.green) }
        } header: {
            Text("Make it stick")
        }
    }

    private func save() {
        var t = task
        t.title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
        t.startDate = t.startDate.startOfDay
        t.timeMinutes = hasTime ? time.minutesSinceMidnight : nil
        if t.recurrence.frequency != .weekly { t.recurrence.weekdays = [] }
        else if t.recurrence.weekdays.isEmpty { t.recurrence.weekdays = [Calendar.current.component(.weekday, from: t.startDate)] }
        if t.reminderOffsets.isEmpty { t.reminderOffsets = [0] }
        if t.isEvent { t.mode = nil }
        t.dueDate = t.isUntilDone && !t.isCycle && !t.recurrence.isRepeating && hasDue ? due.startOfDay : nil
        if t.isHabit {
            t.kind = "habit"
            var h = t.habit ?? HabitInfo()
            for k in [\HabitInfo.identity, \.cue, \.stackAfter, \.replaces, \.twoMinute, \.reward] {
                let v = h[keyPath: k]?.trimmingCharacters(in: .whitespacesAndNewlines)
                h[keyPath: k] = v?.isEmpty == false ? v : nil
            }
            t.habit = h
        } else { t.habit = nil }
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
                Text(cal.veryShortWeekdaySymbols[wd - 1]).font(.callout.weight(.semibold))
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
