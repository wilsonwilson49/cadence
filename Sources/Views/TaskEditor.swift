import SwiftUI

struct TaskEditor: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var google: GoogleCalendar

    let isNew: Bool
    @State private var task: PlanTask
    @State private var newStep = ""
    @State private var hasTime: Bool
    @State private var time: Date
    @State private var endMode: Int
    @State private var endDate: Date
    @State private var endCount: Int
    @State private var addToGoogle = false
    @State private var syncGoogle = false
    @State private var syncDefaultApplied = false
    /// Once you pick open/closed yourself, switching Task/Event no longer changes it.
    @State private var busyChosen = false
    @State private var hasDue: Bool
    @State private var addToGoogleTasks = false
    @State private var cycleGap: Int
    @State private var cycleWeeks: Bool
    @State private var cycleTimes: Int
    @State private var appliedPreset: String?
    @State private var namingPreset = false
    @State private var presetName = ""
    @State private var presetSaved: String?
    @State private var dueDate: Date
    @State private var saving = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var showAllTimes = false

    private static let offsetChoices = [0, 5, 10, 15, 30, 60, 120, 1440]
    /// Reminders partway through a timed task (stored as negative offsets).
    private static let duringChoices = [-10, -15, -30, -45, -60, -90]
    private static let durations = [5, 10, 15, 30, 45, 60, 90, 120, 180, 240]

    init(task: PlanTask, isNew: Bool) {
        self.isNew = isNew
        _task = State(initialValue: task)
        _hasTime = State(initialValue: task.timeMinutes != nil)
        _time = State(initialValue: dayAt(task.startDate, minutes: task.timeMinutes ?? 9 * 60))
        _hasDue = State(initialValue: task.dueDate != nil)
        let gap = task.cycleGapDays
        _cycleWeeks = State(initialValue: gap.map { $0 > 0 && $0 % 7 == 0 } ?? true)
        _cycleGap = State(initialValue: gap.map { $0 > 0 && $0 % 7 == 0 ? $0 / 7 : max(1, $0) } ?? 1)
        _cycleTimes = State(initialValue: task.cycleTimes ?? 3)
        _dueDate = State(initialValue: task.dueDate ?? task.startDate.adding(days: 7))
        switch task.recurrence.end {
        case .never:
            _endMode = State(initialValue: 0); _endDate = State(initialValue: task.startDate.adding(months: 3)); _endCount = State(initialValue: 10)
        case .onDate(let d):
            _endMode = State(initialValue: 1); _endDate = State(initialValue: d); _endCount = State(initialValue: 10)
        case .afterCount(let c):
            _endMode = State(initialValue: 2); _endDate = State(initialValue: task.startDate.adding(months: 3)); _endCount = State(initialValue: c)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(isNew ? "New" : "Edit") \(kindName)").font(.app(.title3).bold())
                Spacer()
                Picker("", selection: Binding(get: { task.isEvent ? "event" : task.isBonus ? "bonus" : task.isHabit ? "habit" : "task" }, set: { k in
                    let wasBonus = task.isBonus
                    task.kind = k
                    if k == "bonus" {
                        // Optional extras: no date to miss, no time, no reminders. A repeat schedule (or a task's
                        // "after it's done, with a break") carries over.
                        task.mode = nil; task.habit = nil
                        task.after = nil; task.afterMinutes = nil; task.armedAt = nil; task.armedBy = nil
                        task.channels = []; task.nag = nil; hasTime = false
                        if isNew && task.color == .blue { task.color = .yellow }
                    } else if wasBonus {
                        task.channels = store.settings.defaultChannels
                        if isNew && task.color == .yellow { task.color = .blue }
                    }
                    if k == "event" { task.mode = nil }   // events have no check-off, so no "until done"/long-term
                    if k == "habit" {
                        // Habits repeat; they start out daily and as building something new.
                        if !task.recurrence.isRepeating { task.recurrence.frequency = .daily }
                        if task.isCycle { task.mode = nil; task.cycleGapDays = nil; task.cycleTimes = nil }
                        if task.habit == nil { task.habit = HabitInfo() }
                        if isNew && task.color == .blue { task.color = .green }
                    }
                    if k == "task" {
                        // Repeating things are habits; a task happens once (or comes back after a break).
                        if task.recurrence.isRepeating { task.recurrence = Recurrence(); endMode = 0 }
                        if task.isLongTerm { task.mode = nil }
                    }
                    if !busyChosen { task.busy = k == "event" }   // events start closed, tasks open
                    if k == "event" && isNew {
                        if !hasTime { hasTime = true; time = dayAt(task.startDate, minutes: 9 * 60) }
                        if task.durationMinutes == 30 { task.durationMinutes = 60 }
                        task.reminderOffsets = [10]
                    }
                })) {
                    Label("Task", systemImage: "checklist").tag("task")
                    Label("Habit", systemImage: "arrow.triangle.2.circlepath").tag("habit")
                    Label("Event", systemImage: "calendar").tag("event")
                    Label("Bonus", systemImage: "star").tag("bonus")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 330)
            }
            .padding([.horizontal, .top], 20)
            Text(task.isEvent ? "Events show on your calendars only: no checkbox, no reflection."
                 : task.isBonus ? "Bonus tasks are optional extras: listed on Today and in Focus, but never required, never overdue and never reminding you. Each one you finish during a focus session is worth +\(Bonus.points) points."
                 : task.isHabit ? "Habits repeat on a schedule and are tracked on the Habits page: streaks, never missing twice, and who you're becoming."
                 : "Tasks go on your checklist; checking one off asks for a short reflection.")
                .font(.app(.caption)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)

            Form {
                if !task.isBonus { presetSection }
                // Text fields are left-aligned throughout: grouped forms right-align them by default, and macOS
                // doesn't draw a trailing space in a right-aligned field until the next character is typed.
                Section {
                    TextField("Title", text: $task.title, prompt: Text("What do you need to do?")).multilineTextAlignment(.leading)
                    TextField("Notes", text: $task.notes, prompt: Text("Optional details"), axis: .vertical).multilineTextAlignment(.leading)
                        .lineLimit(2...5)
                }

                if !task.isEvent {
                    Section("Priority and hardness") {
                        Picker("Priority", selection: $task.priority) {
                            Text("None").tag(String?.none)
                            ForEach(Priority.allCases) { p in Text(p.title).tag(String?.some(p.rawValue)) }
                        }
                        .pickerStyle(.segmented)
                        LabeledContent("Hardness") { HardnessPicker(value: $task.hardness) }
                    }
                    Section {
                        Toggle(isOn: Binding(get: { task.offComputer == true }, set: { task.offComputer = $0 ? true : nil })) {
                            Label("Done away from the computer", systemImage: "figure.walk")
                        }
                    } footer: {
                        Text(task.offComputer == true
                             ? "A focus session on it keeps running while you're away or the Mac sleeps, and a locked screen doesn't count as time away."
                             : "In a focus session, 5 minutes away from the computer (or the Mac going to sleep) pauses it until you're back.")
                            .font(.app(.caption)).foregroundStyle(.secondary)
                    }
                }

                if task.isBonus { bonusSection } else {
                Section("When") {
                    if !task.isEvent && !task.isHabit {
                        Picker("Starts", selection: Binding(get: { task.after != nil }, set: { on in
                            if on { task.after = store.possibleTriggers(for: task.id).first?.id }
                            else { task.after = nil; task.afterMinutes = nil; task.armedAt = nil; task.armedBy = nil }
                        })) {
                            Text("On a date").tag(false)
                            Text("After another task").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    if task.after != nil {
                        followUpControls
                    } else {
                    DatePicker("Date", selection: $task.startDate, displayedComponents: .date)
                    Toggle("At a specific time", isOn: $hasTime)
                    }
                    if hasTime && task.after == nil {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                        Picker("Duration", selection: $task.durationMinutes) {
                            // Its own length too, if it isn't one of these (e.g. set from how long it usually takes).
                            ForEach(Array(Set(Self.durations + [task.durationMinutes])).sorted(), id: \.self) { m in
                                Text(m < 60 ? "\(m) min" : (m % 60 == 0 ? "\(m / 60) hr" : "\(m / 60) hr \(m % 60) min")).tag(m)
                            }
                        }
                    }
                }

                Section {
                    Picker("Your time", selection: Binding(get: { task.isBusy }, set: { task.busy = $0; busyChosen = true })) {
                        Label("Closed", systemImage: "lock.fill").tag(true)
                        Label("Open", systemImage: "eye").tag(false)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Your time")
                } footer: {
                    Text(task.isBusy
                         ? "Blocks this time: it's taken out of your open time on Booking\(task.source == "google" || syncGoogle ? ", and shows as busy in Google Calendar" : "")."
                         : "Just for info: it shows on your calendars, but you're still free to be booked then.")
                        .font(.app(.caption)).foregroundStyle(.secondary)
                }

                if !overlaps.isEmpty {
                    Section {
                        ForEach(overlaps, id: \.self) { line in
                            Label(line, systemImage: "square.stack.3d.up").font(.app(.callout))
                        }
                        Text("That's fine: this task's reminders will still fire on time, even in the middle of the other one.")
                            .font(.app(.caption)).foregroundStyle(.secondary)
                    } header: {
                        Text("Overlaps with")
                    }
                }

                }

                if task.isBonus {
                } else if task.source == "google" && !isNew {
                    Section("Synced with Google Calendar") {
                        Label("Changes you save here update the event in Google Calendar, and changes made in Google show up here. Repeats are managed in Google Calendar.",
                              systemImage: "arrow.triangle.2.circlepath")
                            .font(.app(.callout))
                        if let u = task.externalURL.flatMap(URL.init(string:)) { Link("Open in Google Calendar", destination: u) }
                    }
                } else if task.after == nil {
                Section(task.isHabit || task.isEvent ? "Repeat" : "Conditions") {
                    Picker(task.isHabit || task.isEvent ? "Repeats" : "Comes back", selection: repeatChoice) {
                        if task.isHabit {
                            ForEach(Frequency.allCases.filter { $0 != .none }) { Text($0.label).tag($0.rawValue) }
                            Text("Long-term: every day until a date").tag("longTerm")
                        } else if task.isEvent {
                            ForEach(Frequency.allCases) { Text($0.label).tag($0.rawValue) }
                        } else {
                            Text("No, just once").tag(Frequency.none.rawValue)
                            Text("After it's done, with a break").tag("cycle")
                        }
                    }
                    if task.isCycle {
                        HStack {
                            Stepper(value: $cycleGap, in: 1...365) { Text("Break before it comes back: \(cycleGap)") }
                            Picker("", selection: $cycleWeeks) { Text(cycleGap == 1 ? "day" : "days").tag(false); Text(cycleGap == 1 ? "week" : "weeks").tag(true) }
                                .labelsHidden().fixedSize()
                        }
                        Stepper("Times in total: \(cycleTimes)", value: $cycleTimes, in: 1...99)
                        Label("No dates: it stays on your list every day until you check it off (or mark it “didn't do it”), then takes a \(cycleGap)-\(cycleWeeks ? "week" : "day") break and comes back — \(cycleTimes) time\(cycleTimes == 1 ? "" : "s") in total, then it's finished for good.",
                              systemImage: "flame")
                            .font(.app(.caption)).foregroundStyle(.secondary)
                    } else if task.isLongTerm {
                        DatePicker("Every day until", selection: $endDate, in: task.startDate..., displayedComponents: .date)
                        Label("On your checklist and reminds you every day until \(endDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) (\(max(0, Calendar.current.dateComponents([.day], from: task.startDate.startOfDay, to: endDate.startOfDay).day ?? 0) + 1) days). Check off each day on its own.",
                              systemImage: "repeat")
                            .font(.app(.caption)).foregroundStyle(.secondary)
                    } else if task.recurrence.isRepeating {
                        Stepper(value: $task.recurrence.interval, in: 1...99) {
                            Text(task.recurrence.interval == 1 ? "Every \(task.recurrence.frequency.unit)"
                                 : "Every \(task.recurrence.interval) \(task.recurrence.frequency.unit)s")
                        }
                        if task.recurrence.frequency == .weekly {
                            WeekdayPicker(selection: $task.recurrence.weekdays)
                        }
                        Picker("Ends", selection: $endMode) {
                            Text("Never").tag(0)
                            Text("On a date").tag(1)
                            Text("After a number of times").tag(2)
                        }
                        if endMode == 1 {
                            DatePicker("End date", selection: $endDate, in: task.startDate..., displayedComponents: .date)
                        } else if endMode == 2 {
                            Stepper("\(endCount) times", value: $endCount, in: 1...999)
                        }
                        Text(previewRecurrence.summary(start: task.startDate))
                            .font(.app(.caption)).foregroundStyle(.secondary)
                    }
                    // "Keep it on my list until it's done" works with any repeat except long-term.
                    if !task.isEvent && !task.isLongTerm && !task.isCycle {
                        Toggle(isOn: Binding(get: { task.isUntilDone }, set: { task.mode = $0 ? "untilDone" : nil })) {
                            Label("Keep it on my list every day until it's done", systemImage: "flame")
                        }
                        if task.isUntilDone {
                            Text(task.recurrence.isRepeating
                                 ? "Each one shows up and reminds you every day until you check it off or mark it “didn't do it”, or until the next one arrives and takes its place."
                                 : "It shows up and reminds you every day until you check it off or mark it “didn't do it”. Then it's gone.")
                                .font(.app(.caption)).foregroundStyle(.secondary)
                            if !task.recurrence.isRepeating {
                                Toggle("Has a due date", isOn: $hasDue)
                                if hasDue {
                                    DatePicker("Due by", selection: $dueDate, in: task.startDate..., displayedComponents: .date)
                                    Text("It keeps going past the due date, marked “Past due”.").font(.app(.caption)).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                }

                if !task.isBonus {
                Section {
                    Toggle(isOn: Binding(get: { !task.channels.isEmpty },
                                         set: { task.channels = $0 ? store.settings.defaultChannels : [] })) {
                        Label(task.channels.isEmpty ? "No notifications — stays on the checklist quietly" : "Notify me about this task",
                              systemImage: task.channels.isEmpty ? "bell.slash" : "bell")
                    }
                    if !task.channels.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(Self.offsetChoices, id: \.self) { off in
                            Toggle(offsetString(off), isOn: setBinding($task.reminderOffsets, off))
                                .toggleStyle(.checkbox)
                        }
                    }
                    if hasTime {
                        Text("During the task").font(.app(.callout).weight(.medium)).padding(.top, 4)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(Self.duringChoices.filter { -$0 < task.durationMinutes }, id: \.self) { off in
                                Toggle(offsetString(off), isOn: setBinding($task.reminderOffsets, off))
                                    .toggleStyle(.checkbox)
                            }
                        }
                    }
                    ChannelToggles(channels: $task.channels)
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    if task.isImported {
                        Text("Imported from \(task.source == "calendly" ? "Calendly" : "Google Calendar"). Its title and time update on each import.")
                            .font(.app(.caption)).foregroundStyle(.secondary)
                    } else if !hasTime && !task.channels.isEmpty {
                        Text("Tasks without a time remind at \(timeString(minutes: store.settings.untimedReminderMinutes)) on the day (change in Settings).")
                            .font(.app(.caption)).foregroundStyle(.secondary)
                    }
                }

                }

                if !task.isEvent && !task.isBonus {
                    Section {
                        Picker("Keep after me", selection: Binding(get: { task.nagLevel }, set: { task.nag = $0 == .normal ? nil : $0.rawValue })) {
                            ForEach(NagLevel.allCases) { l in Label(l.title, systemImage: l.symbol).tag(l) }
                        }
                        .pickerStyle(.segmented)
                        Text(task.nagLevel.detail).font(.app(.caption)).foregroundStyle(.secondary)
                        if task.nagLevel != .normal {
                            Picker("Comes back every", selection: Binding(get: { task.nagMinutes }, set: { task.nagEvery = $0 == 10 ? nil : $0 })) {
                                ForEach(NagLevel.everyChoices, id: \.self) { m in Text(m == 60 ? "hour" : "\(m) min").tag(m) }
                            }
                            Button("Preview") { model.nag.preview(task.nagLevel) }.help("Shows what it will look like, without starting it")
                        }
                    } header: { Text("For things you'd rather put off") } footer: {
                        if task.nagLevel == .strict {
                            Text("Blocks the apps on your distracting list (Screen Time) and the websites in Settings › Tough love, until this is checked off.")
                                .font(.app(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }

                if !task.isEvent && !task.isHabit { followUpsSection }
                if !task.isEvent { timeTakenSection }

                Section("Color") {
                    HStack(spacing: 10) {
                        ForEach(TaskColor.allCases) { c in
                            Circle().fill(c.color).frame(width: 22, height: 22)
                                .overlay(Circle().strokeBorder(.white, lineWidth: task.color == c ? 2.5 : 0))
                                .overlay(Circle().strokeBorder(Color.primary.opacity(task.color == c ? 0.5 : 0), lineWidth: 1).padding(-2))
                                .onTapGesture { task.color = c }
                                .help(c.rawValue.capitalized)
                        }
                    }
                }

                if task.isHabit { stepsSection; habitSection }

                if google.isConnected && google.tasksGranted && isNew && !task.isEvent && !task.isHabit && !task.isBonus && task.source == nil {
                    Section("Google Tasks") {
                        Toggle(isOn: $addToGoogleTasks) { Label("Also add to Google Tasks", systemImage: "checklist") }
                    }
                }
                if task.source == "gtasks" {
                    Section { Label("Synced with Google Tasks: title, notes, due date and checking it off update Google too.", systemImage: "arrow.triangle.2.circlepath").font(.app(.caption)) }
                }

                if google.isConnected && task.googleEventID == nil && task.source == nil && !task.isHabit && !task.isBonus {
                    Section("Google Calendar") {
                        if task.isEvent {
                            Toggle(isOn: $syncGoogle) { Label("Sync with Google Calendar", systemImage: "arrow.triangle.2.circlepath") }
                            Text(syncGoogle ? "Creates it in your Google Calendar\(task.recurrence.isRepeating ? " (with the repeat schedule)" : ""); edits stay in sync both ways."
                                            : "Keep this event in Cadence only.")
                                .font(.app(.caption)).foregroundStyle(.secondary)
                        } else {
                            Toggle("Also add to Google Calendar", isOn: $addToGoogle)
                            if addToGoogle && task.recurrence.isRepeating {
                                Text("The repeat schedule is copied to Google too.").font(.app(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { model.editingTask = nil }.keyboardShortcut(.cancelAction)
                Button(isNew ? (task.isEvent ? "Add Event" : task.isBonus ? "Add Bonus Task" : "Add Task") : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
            .padding(16)
        }
        .frame(width: 560, height: 700)
        .onChange(of: task.recurrence.frequency) { _, f in
            if f == .weekly && task.recurrence.weekdays.isEmpty {
                task.recurrence.weekdays = [Calendar.current.component(.weekday, from: task.startDate)]
            }
        }
        .confirmationDialog(isGoogleSynced ? "Remove “\(task.title)”?" : "Delete “\(task.title)”?", isPresented: $confirmDelete) {
            if isGoogleSynced {
                Button("Hide in Cadence") { store.delete(taskID: task.id); model.editingTask = nil }
                Button("Delete from Google Calendar too", role: .destructive) {
                    let t = task
                    Task {
                        do {
                            try await google.deleteEvent(calendarID: t.sourceCalendar ?? "primary", eventID: t.googleEventID ?? "")
                            store.delete(taskID: t.id)
                            model.editingTask = nil
                        } catch {
                            self.error = "Google Calendar didn't delete it: \(error.localizedDescription)"
                        }
                    }
                }
            } else {
                if task.recurrence.isRepeating, let next = store.task(task.id)?.nextOccurrence(onOrAfter: Date()) {
                    Button("Only the next one (\(next.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())))") {
                        if let t = store.task(task.id) { store.delete(Occurrence(task: t, day: next), scope: .one) }
                        model.editingTask = nil
                    }
                    Button("Stop it from now on (keep the past)") {
                        if let t = store.task(task.id) { store.delete(Occurrence(task: t, day: next), scope: .fromHere) }
                        model.editingTask = nil
                    }
                }
                Button(task.recurrence.isRepeating ? "Delete all of them" : task.isEvent ? "Delete event" : "Delete task", role: .destructive) {
                    store.delete(taskID: task.id)
                    model.editingTask = nil
                }
            }
        } message: {
            Text(isGoogleSynced ? "This event is synced with Google Calendar." : task.recurrence.isRepeating ? "It repeats. To delete one particular day, you can also right-click it on your list or calendar." : task.isEvent ? "This can't be undone." : "Reflections you've written for it are kept.")
        }
        .onAppear {
            // New events sync with Google Calendar by default when it's connected.
            if !syncDefaultApplied { syncDefaultApplied = true; syncGoogle = isNew && task.isEvent && google.isConnected }
        }
        .onChange(of: task.kind) { _, _ in if isNew { syncGoogle = task.isEvent && google.isConnected } }
    }

    /// Other timed tasks / Google events this one overlaps on its start day.
    private var overlaps: [String] {
        guard hasTime else { return [] }
        let day = task.startDate.startOfDay
        let start = dayAt(day, minutes: time.minutesSinceMidnight)
        let end = start.adding(minutes: task.durationMinutes)
        var lines: [String] = []
        for occ in store.occurrences(on: day) where occ.task.id != task.id {
            if let s = occ.start, let e = occ.end, s < end, e > start {
                lines.append("\(occ.task.title) · \(timeString(s))–\(timeString(e))")
            }
        }
        for ev in google.events(on: day) where !ev.isAllDay && ev.start < end && ev.end > start {
            lines.append("\(ev.title) · \(timeString(ev.start))–\(timeString(ev.end)) (Google)")
        }
        return lines
    }

    private var isGoogleSynced: Bool { task.source == "google" && task.googleEventID != nil && google.isConnected }

    private var kindName: String { task.isEvent ? "Event" : task.isBonus ? "Bonus Task" : task.isHabit ? "Habit" : "Task" }

    // MARK: Bonus tasks

    /// When it's on your list from, and how many times it can be checked off.
    @ViewBuilder private var bonusSection: some View {
        let limit = task.bonusLimit ?? 1
        let saved = store.task(task.id)
        let repeats = task.cycleGapDays != nil || task.recurrence.isRepeating
        Section {
            DatePicker(repeats ? "Starts" : "On your list from", selection: $task.startDate, displayedComponents: .date)
            Picker(repeats ? "Each time, it can be checked off" : "Can be checked off", selection: Binding(get: { limit }, set: {
                task.bonusLimit = $0 == 1 ? nil : $0
                if $0 <= 0 { task.cycleGapDays = nil; task.cycleTimes = nil }   // with no limit, it's never "done"
            })) {
                ForEach(Array(Set(Bonus.limitChoices + [limit])).sorted { ($0 <= 0 ? Int.max : $0) < ($1 <= 0 ? Int.max : $1) }, id: \.self) { n in
                    Text(Bonus.limitLabel(n)).tag(n)
                }
            }
            if limit > 0 {
                Stepper("Or exactly: \(limit) time\(limit == 1 ? "" : "s")", value: Binding(get: { limit }, set: { task.bonusLimit = $0 == 1 ? nil : $0 }), in: 1...999)
            }
            if let saved, saved.bonusCount > 0 {
                LabeledContent("So far") {
                    Text("Checked off \(saved.bonusCount) time\(saved.bonusCount == 1 ? "" : "s")\(saved.bonusFinished ? ": all done" : repeats ? " (this time: \(saved.bonusSummary.lowercased()))" : "")")
                        .foregroundStyle(.secondary)
                }
            }
        } header: { Text("Bonus") } footer: {
            Text(limit <= 0 ? "No limit: check it off as many times as you like (several times a day too)\(repeats ? ", each time it comes around" : "")."
                 : limit == 1 ? (repeats ? "Check it off once each time it comes around." : "Check it off once and it's done for good. It never shows as overdue or missed if you don't.")
                 : "It stays on your list until you've checked it off \(limit) times (several times a day is fine)\(repeats ? ", then waits until it comes around again" : ", then it's done for good").")
                .font(.app(.caption)).foregroundStyle(.secondary)
        }
        Section {
            Picker("Comes back", selection: bonusRepeat) {
                Text("No, just once").tag(Frequency.none.rawValue)
                ForEach(Frequency.allCases.filter { $0 != .none }) { Text($0.label).tag($0.rawValue) }
                if limit > 0 { Text("After it's done, with a break").tag("cycle") }
            }
            if task.cycleGapDays != nil {
                HStack {
                    Stepper(value: $cycleGap, in: 1...365) { Text("Break before it comes back: \(cycleGap)") }
                    Picker("", selection: $cycleWeeks) { Text(cycleGap == 1 ? "day" : "days").tag(false); Text(cycleGap == 1 ? "week" : "weeks").tag(true) }
                        .labelsHidden().fixedSize()
                }
                Stepper("Times in total: \(cycleTimes)", value: $cycleTimes, in: 1...99)
                Label("Once it's been checked off\(limit == 1 ? "" : " \(limit) times"), it takes a \(cycleGap)-\(cycleWeeks ? "week" : "day") break and comes back: \(cycleTimes) time\(cycleTimes == 1 ? "" : "s") in total.",
                      systemImage: "flame")
                    .font(.app(.caption)).foregroundStyle(.secondary)
            } else if task.recurrence.isRepeating {
                Stepper(value: $task.recurrence.interval, in: 1...99) {
                    Text(task.recurrence.interval == 1 ? "Every \(task.recurrence.frequency.unit)"
                         : "Every \(task.recurrence.interval) \(task.recurrence.frequency.unit)s")
                }
                if task.recurrence.frequency == .weekly {
                    WeekdayPicker(selection: $task.recurrence.weekdays)
                }
                Picker("Ends", selection: $endMode) {
                    Text("Never").tag(0)
                    Text("On a date").tag(1)
                    Text("After a number of times").tag(2)
                }
                if endMode == 1 {
                    DatePicker("End date", selection: $endDate, in: task.startDate..., displayedComponents: .date)
                } else if endMode == 2 {
                    Stepper("\(endCount) times", value: $endCount, in: 1...999)
                }
                Text("\(previewRecurrence.summary(start: task.startDate)). Each time it comes around it's a fresh start: anything not checked off doesn't carry over.")
                    .font(.app(.caption)).foregroundStyle(.secondary)
            }
        } header: { Text("Comes back") }
    }

    /// A bonus task's "Comes back": just once, on a schedule (like a habit's), or after it's done with a break (like a task's).
    private var bonusRepeat: Binding<String> {
        Binding(get: { task.cycleGapDays != nil ? "cycle" : task.recurrence.frequency.rawValue }, set: { v in
            if v == "cycle" {
                task.recurrence = Recurrence(); endMode = 0
                task.cycleGapDays = cycleGap * (cycleWeeks ? 7 : 1); task.cycleTimes = cycleTimes
            } else {
                task.cycleGapDays = nil; task.cycleTimes = nil
                task.recurrence.frequency = Frequency(rawValue: v) ?? .none
            }
        })
    }

    // MARK: Habits (Atomic Habits)

    private func habitBinding(_ key: WritableKeyPath<HabitInfo, String?>) -> Binding<String> {
        Binding(get: { task.habit?[keyPath: key] ?? "" }, set: { v in
            var h = task.habit ?? HabitInfo(); h[keyPath: key] = v.isEmpty ? nil : v; task.habit = h
        })
    }

    /// Steps: a small checklist that starts fresh each time the habit comes around.
    /// "After another task": which one, how long after, and where it stands.
    @ViewBuilder private var followUpControls: some View {
        let options = store.possibleTriggers(for: task.id)
        if options.isEmpty {
            Text("There's no other task for it to follow yet.").font(.app(.caption)).foregroundStyle(.secondary)
        } else {
            Picker("After", selection: $task.after) {
                ForEach(options) { t in Text(t.title.isEmpty ? "Untitled" : t.title).tag(Optional(t.id)) }
            }
            Picker("Comes up", selection: Binding(get: { task.afterMinutes ?? 0 }, set: { task.afterMinutes = $0 == 0 ? nil : $0 })) {
                ForEach(PlanTask.afterChoices, id: \.self) { m in Text(PlanTask.afterLabel(m)).tag(m) }
            }
            Picker("Duration", selection: $task.durationMinutes) {
                ForEach(Array(Set(Self.durations + [task.durationMinutes])).sorted(), id: \.self) { m in Text(TaskStats.format(m)).tag(m) }
            }
            Toggle(isOn: Binding(get: { task.isUntilDone }, set: { task.mode = $0 ? "untilDone" : nil })) {
                Label("Once it's up, keep it on my list until it's done", systemImage: "flame")
            }
            let trigger = task.after.flatMap(store.task)?.title ?? "that task"
            Label(task.armedAt == nil
                  ? "Off your list until “\(trigger)” is checked off; then it comes up \(PlanTask.afterLabel(task.afterMinutes ?? 0).lowercased()) with a reminder."
                  : "Came up at \(task.timeMinutes.map { timeString(minutes: $0) } ?? "—") on \(task.startDate.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) after “\(trigger)” was checked off. It comes up again the next time.",
                  systemImage: "arrow.turn.down.right")
                .font(.app(.caption)).foregroundStyle(.secondary)
        }
    }

    /// The tasks that follow this one, and a way to add another.
    @ViewBuilder private var followUpsSection: some View {
        let list = store.followUps(of: task.id)
        Section {
            ForEach(list) { f in
                HStack {
                    Image(systemName: "arrow.turn.down.right").foregroundStyle(.secondary)
                    Text(f.title)
                    Spacer()
                    Text(PlanTask.afterLabel(f.afterMinutes ?? 0)).foregroundStyle(.secondary)
                    Button("Edit") { save(); DispatchQueue.main.async { model.editingTask = f } }.buttonStyle(.link)
                }
            }
            Button { save(); let id = task.id; DispatchQueue.main.async { model.editingTask = PlanTask(title: "", startDate: Date().startOfDay, after: id) } } label: {
                Label("Add a task that follows this one…", systemImage: "plus")
            }
            .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: { Text("Then") } footer: {
            Text("Follow-ups wait off your list until this is checked off, then come up on their own: chain the next step to the last.")
                .font(.app(.caption)).foregroundStyle(.secondary)
        }
    }

    /// How long it really took each time it was checked off, and how long it usually takes (the 60% mark).
    @ViewBuilder private var timeTakenSection: some View {
        let entries = (task.timeTaken ?? [:]).sorted { $0.key > $1.key }
        Section {
            if entries.isEmpty {
                Text("Not timed yet. When you check it off, you can write down how long it took, and this shows how long it usually takes.")
                    .font(.app(.caption)).foregroundStyle(.secondary)
            } else {
                TimeSpread(times: task.takenTimes).padding(.vertical, 2)
                if let line = TaskStatsText.typical(task) { Text(line).font(.app(.caption)).foregroundStyle(.secondary) }
                if let typical = task.typicalMinutes, typical != task.durationMinutes {
                    Button("Plan \(TaskStats.format(typical)) for it") { task.durationMinutes = typical }
                        .help("Sets its length to how long it usually takes")
                }
                ForEach(entries.prefix(showAllTimes ? entries.count : 6), id: \.key) { e in
                    HStack {
                        Text(DateKey.date(e.key)?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()) ?? e.key)
                        Spacer()
                        Text(TaskStats.format(e.value)).monospacedDigit()
                        Button {
                            task.timeTaken?[e.key] = nil
                            if task.timeTaken?.isEmpty == true { task.timeTaken = nil }
                        } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove this time")
                    }
                }
                if entries.count > 6 {
                    Button(showAllTimes ? "Show fewer" : "Show all \(entries.count)") { showAllTimes.toggle() }.buttonStyle(.link)
                }
            }
        } header: { Text("Time it took") }
    }

    @ViewBuilder private var stepsSection: some View {
        Section {
            ForEach(Array(task.habitSteps.enumerated()), id: \.element.id) { i, s in
                HStack {
                    Image(systemName: "square").foregroundStyle(.secondary)
                    TextField("Step \(i + 1)", text: Binding(get: { task.habitSteps.indices.contains(i) ? task.habitSteps[i].title : "" },
                                                            set: { v in if task.steps?.indices.contains(i) == true { task.steps?[i].title = v } }))
                        .textFieldStyle(.plain)
                    Button { moveStep(i, -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(.borderless).disabled(i == 0)
                    Button { moveStep(i, 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(.borderless).disabled(i == task.habitSteps.count - 1)
                    Button { task.steps?.remove(at: i); if task.steps?.isEmpty == true { task.steps = nil } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.red)
                }
            }
            HStack {
                Image(systemName: "plus.circle.fill").foregroundStyle(task.color.color)
                TextField("Add a step — press Return", text: $newStep).textFieldStyle(.plain).onSubmit(addStep)
            }
        } header: {
            Text("Steps")
        } footer: {
            Text("Optional. Break the habit into steps you tick off each time, e.g. stretch, journal, make the bed. They start fresh every time it comes around; ticking the last one opens the check-off.")
                .font(.app(.caption)).foregroundStyle(.secondary)
        }
    }

    private func addStep() {
        let t = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        task.steps = task.habitSteps + [HabitStep(title: t)]
        newStep = ""
    }

    private func moveStep(_ i: Int, _ d: Int) {
        guard var s = task.steps, s.indices.contains(i + d) else { return }
        s.swapAt(i, i + d); task.steps = s
    }

    @ViewBuilder private var habitSection: some View {
        let style = task.habit?.style ?? "build"
        Section {
            Picker("Style", selection: Binding(get: { style }, set: { v in var h = task.habit ?? HabitInfo(); h.style = v; task.habit = h })) {
                ForEach(HabitInfo.styles, id: \.id) { Text($0.label).tag($0.id) }
            }
            .pickerStyle(.segmented)
            if style == "stack" {
                TextField("After I…", text: habitBinding(\.stackAfter), prompt: Text("pour my morning coffee")).multilineTextAlignment(.leading)
            }
            if style == "replace" {
                TextField("Instead of…", text: habitBinding(\.replaces), prompt: Text("scrolling my phone in bed")).multilineTextAlignment(.leading)
            }
            if style == "break" {
                TextField("Screen-time app to keep down", text: habitBinding(\.app), prompt: Text("YouTube (optional)")).multilineTextAlignment(.leading)
                Stepper(value: Binding(get: { task.habit?.limitMinutes ?? 30 }, set: { v in var h = task.habit ?? HabitInfo(); h.limitMinutes = v; task.habit = h }),
                        in: 5...600, step: 5) { Text("Daily limit: \(task.habit?.limitMinutes ?? 30) min") }
            }
            TextField("I am someone who…", text: habitBinding(\.identity), prompt: Text("reads every day")).multilineTextAlignment(.leading)
            TextField("When and where", text: habitBinding(\.cue), prompt: Text("at 9 PM on the couch")).multilineTextAlignment(.leading)
            TextField("2-minute version", text: habitBinding(\.twoMinute), prompt: Text("read one page")).multilineTextAlignment(.leading)
            TextField("Right after, I get…", text: habitBinding(\.reward), prompt: Text("a cup of tea")).multilineTextAlignment(.leading)
            if let s = task.habitSentence { Label(s, systemImage: "quote.opening").font(.app(.callout)).italic().foregroundStyle(.green) }
        } header: {
            Text("Make it stick")
        } footer: {
            Text("Who you're becoming (identity), make it obvious (cue), easy (2 minutes) and satisfying (reward). For a habit to break, the Mac's screen time can track an app against a daily limit.")
                .font(.app(.caption)).foregroundStyle(.secondary)
        }
    }

    // MARK: Presets

    @ViewBuilder private var presetSection: some View {
        Section {
            HStack(spacing: 10) {
                Image(systemName: "square.stack").foregroundStyle(Color.accentColor)
                if isNew && !store.settings.taskPresets.isEmpty {
                    Menu(appliedPreset ?? "Start from a preset…") {
                        ForEach(store.settings.taskPresets) { p in
                            Button(p.name) { apply(p) }
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                if let presetSaved {
                    Label("Saved “\(presetSaved)”", systemImage: "checkmark").font(.app(.caption)).foregroundStyle(.green)
                }
                Button { presetName = task.title.trimmingCharacters(in: .whitespaces); namingPreset = true } label: {
                    Label("Save as preset", systemImage: "plus")
                }
                .help("Save these conditions (repeat, keep until done, reminders, color…) to reuse")
            }
        }
        .alert("Save as preset", isPresented: $namingPreset) {
            TextField("Preset name", text: $presetName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                store.settings.taskPresets.append(makePreset(name: name.isEmpty ? "My preset" : name))
                presetSaved = name.isEmpty ? "My preset" : name
            }
        } message: {
            Text("Saves this task's conditions (repeat, keep until done, due date, reminders, color, open/closed) to start new tasks from.")
        }
    }

    private func makePreset(name: String) -> TaskPreset {
        let day = task.startDate.startOfDay
        let days: (Date) -> Int = { max(0, Calendar.current.dateComponents([.day], from: day, to: $0.startOfDay).day ?? 0) }
        var r = task.recurrence
        if r.frequency != .weekly { r.weekdays = [] }
        r.end = endMode == 2 && r.isRepeating ? .afterCount(endCount) : .never
        var p = TaskPreset(name: name, kind: task.isEvent ? "event" : "task", timeMinutes: hasTime ? time.minutesSinceMidnight : nil,
                           durationMinutes: task.durationMinutes, recurrence: r, reminderOffsets: task.reminderOffsets.sorted(),
                           color: task.color, busy: task.isBusy, mode: task.mode)
        p.title = task.title.trimmingCharacters(in: .whitespaces)
        p.notes = task.notes
        p.channels = AlertChannel.allCases.filter { task.channels.contains($0) }
        if task.isCycle { p.cycleGapDays = cycleGap * (cycleWeeks ? 7 : 1); p.cycleTimes = cycleTimes }
        if endMode == 1 && r.isRepeating { p.spanDays = days(endDate) }
        if task.isUntilDone && !r.isRepeating && hasDue { p.dueDays = days(dueDate) }
        return p
    }

    private func apply(_ p: TaskPreset) {
        let day = task.startDate.startOfDay
        task.kind = p.kind == "event" ? "event" : "task"
        if task.title.trimmingCharacters(in: .whitespaces).isEmpty { task.title = p.title }
        if task.notes.trimmingCharacters(in: .whitespaces).isEmpty { task.notes = p.notes }
        task.durationMinutes = p.durationMinutes
        task.color = p.color
        task.busy = p.busy ?? (p.kind == "event")
        busyChosen = true
        var r = p.recurrence
        r.end = .never
        task.recurrence = r
        task.mode = p.mode
        task.cycleGapDays = p.cycleGapDays; task.cycleTimes = p.cycleTimes
        if let g = p.cycleGapDays {
            cycleWeeks = g > 0 && g % 7 == 0; cycleGap = cycleWeeks ? g / 7 : max(1, g); cycleTimes = p.cycleTimes ?? 3
            task.cycleTimes = cycleTimes
        }
        task.reminderOffsets = Set(p.reminderOffsets.isEmpty ? [0] : p.reminderOffsets)
        task.channels = Set(p.channels)
        hasTime = p.timeMinutes != nil
        if let m = p.timeMinutes { time = dayAt(day, minutes: m) }
        if let span = p.spanDays { endMode = 1; endDate = day.adding(days: span) }
        else if case .afterCount(let n) = p.recurrence.end { endMode = 2; endCount = n }
        else { endMode = 0 }
        hasDue = p.dueDays != nil
        if let d = p.dueDays { dueDate = day.adding(days: d) }
        if task.isEvent { syncGoogle = google.isConnected }
        appliedPreset = p.name
        presetSaved = nil
    }

    /// The Repeats menu: a frequency, or one of the "keep reminding me" types.
    private var repeatChoice: Binding<String> {
        Binding(get: { task.isLongTerm ? "longTerm" : task.isCycle ? "cycle" : task.recurrence.frequency.rawValue }, set: { v in
            if v != "cycle" && task.isCycle { task.mode = nil; task.cycleGapDays = nil; task.cycleTimes = nil }
            switch v {
            case "cycle":
                // After it's done, with a break: no dates, so no repeat schedule.
                task.mode = "untilDone"
                task.recurrence = Recurrence()
                task.cycleGapDays = cycleGap * (cycleWeeks ? 7 : 1)
                task.cycleTimes = cycleTimes
            case "longTerm":
                task.cycleGapDays = nil; task.cycleTimes = nil
                task.mode = v
                task.recurrence.frequency = .daily; task.recurrence.interval = 1; task.recurrence.weekdays = []
                endMode = 1
                if endDate <= task.startDate { endDate = task.startDate.adding(days: 30) }
            default:
                if task.isLongTerm { task.mode = nil; endMode = 0 }
                task.recurrence.frequency = Frequency(rawValue: v) ?? .none
            }
        })
    }

    private var previewRecurrence: Recurrence {
        var r = task.recurrence
        r.end = endMode == 1 ? .onDate(endDate) : endMode == 2 ? .afterCount(endCount) : .never
        return r
    }

    private func save() {
        var t = task
        t.title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
        t.startDate = t.startDate.startOfDay
        t.timeMinutes = hasTime ? time.minutesSinceMidnight : nil
        t.recurrence = previewRecurrence
        if t.recurrence.frequency != .weekly { t.recurrence.weekdays = [] }
        if t.isEvent { t.mode = nil }
        if t.after != nil {
            // A follow-up keeps the date and time it was set off at (or none yet); it has no schedule of its own.
            t.startDate = task.startDate.startOfDay
            t.timeMinutes = task.armedAt == nil ? nil : task.timeMinutes
            if store.task(t.id)?.after != t.after { t.armedAt = nil; t.armedBy = nil }
        }
        if t.isLongTerm {
            t.recurrence = Recurrence(frequency: .daily, interval: 1, weekdays: [], end: .onDate(max(endDate, t.startDate).startOfDay))
        }
        if t.isCycle && t.after == nil {
            t.cycleGapDays = cycleGap * (cycleWeeks ? 7 : 1); t.cycleTimes = cycleTimes
            t.recurrence = Recurrence()
        } else { t.cycleGapDays = nil; t.cycleTimes = nil }
        if t.after != nil { t.recurrence = Recurrence(); if t.isLongTerm { t.mode = nil } }
        t.dueDate = t.isUntilDone && !t.isCycle && !t.recurrence.isRepeating && hasDue ? dueDate.startOfDay : nil
        let pending = newStep.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pending.isEmpty { t.steps = t.habitSteps + [HabitStep(title: pending)] }
        let steps = t.habitSteps.map { var s = $0; s.title = s.title.trimmingCharacters(in: .whitespacesAndNewlines); return s }.filter { !$0.title.isEmpty }
        t.steps = t.isHabit && !steps.isEmpty ? steps : nil
        if t.steps == nil { t.stepsDone = nil }
        if t.isHabit {
            t.kind = "habit"
            var h = t.habit ?? HabitInfo()
            for k in [\HabitInfo.identity, \.cue, \.stackAfter, \.replaces, \.twoMinute, \.reward, \.app] {
                let v = h[keyPath: k]?.trimmingCharacters(in: .whitespacesAndNewlines)
                h[keyPath: k] = v?.isEmpty == false ? v : nil
            }
            if h.style != "break" { h.app = nil; h.limitMinutes = nil }
            t.habit = h
        } else { t.habit = nil }
        if t.isBonus {
            t.timeMinutes = nil; t.mode = nil; t.dueDate = nil; t.urgent = nil
            if task.cycleGapDays != nil && t.bonusMax != nil {
                t.recurrence = Recurrence(); t.cycleGapDays = cycleGap * (cycleWeeks ? 7 : 1); t.cycleTimes = cycleTimes
            } else { t.cycleGapDays = nil; t.cycleTimes = nil }
            t.after = nil; t.afterMinutes = nil; t.armedAt = nil; t.armedBy = nil
            t.channels = []; t.nag = nil; t.nagEvery = nil; t.busy = false
            if let l = t.bonusLimit, l == 1 { t.bonusLimit = nil }
        } else { t.bonusLimit = nil }

        // A Google Tasks item: save here, then push the title/notes/due date to Google.
        if !isNew, t.source == "gtasks", let gid = t.googleTaskID {
            store.upsert(t)
            model.editingTask = nil
            var fields: [String: Any] = ["title": t.title, "notes": t.notes]
            fields["due"] = t.dueDate.map(DateKey.string) ?? NSNull()
            Task { try? await google.updateGoogleTask(listID: t.sourceCalendar ?? "@default", taskID: gid, fields: fields) }
            return
        }
        // A new task that also goes to Google Tasks: create it there, then keep it as the synced copy.
        if isNew && addToGoogleTasks && !t.isEvent && !t.isHabit && google.tasksGranted {
            saving = true
            Task {
                do {
                    let gt = try await google.createGoogleTask(title: t.title, notes: t.notes, due: DateKey.string(t.dueDate ?? t.startDate))
                    var synced = t
                    synced.id = stableUUID("gtasks:\(gt.id)")
                    synced.source = "gtasks"; synced.googleTaskID = gt.id; synced.sourceCalendar = gt.listID; synced.externalURL = gt.link
                    synced.kind = "task"
                    store.upsert(synced)
                    model.editingTask = nil
                } catch {
                    store.upsert(t)
                    self.error = "Saved in Cadence only — Google Tasks failed: \(error.localizedDescription)"
                }
                saving = false
            }
            return
        }
        // "During" reminders only make sense inside a timed task's span.
        t.reminderOffsets = t.reminderOffsets.filter { $0 >= 0 || (t.timeMinutes != nil && -$0 < t.durationMinutes) }
        if t.reminderOffsets.isEmpty { t.reminderOffsets = [0] }
        let start0 = t.timeMinutes.map { dayAt(t.startDate, minutes: $0) } ?? t.startDate
        let googleEvent = NewGoogleEvent(title: t.title, details: t.notes, start: start0,
                                         end: start0.adding(minutes: t.durationMinutes), allDay: t.timeMinutes == nil,
                                         rrule: t.recurrence.rrule(start: t.startDate), busy: t.isBusy)

        // Editing an event synced with Google: save here, then push the change to Google.
        if !isNew, t.source == "google", let eventID = t.googleEventID {
            store.upsert(t)
            model.editingTask = nil
            var update = googleEvent
            update.rrule = nil
            Task { try? await google.update(calendarID: t.sourceCalendar ?? "primary", eventID: eventID, update) }
            return
        }

        // A new event that syncs with Google: create it there first, then keep it as the synced copy
        // (same ID the importer would give it, so it's never imported twice).
        if isNew && t.isEvent && syncGoogle && google.isConnected {
            saving = true
            Task {
                do {
                    let ev = try await google.create(googleEvent)
                    if !t.recurrence.isRepeating, let ev {
                        let raw = ev.id.split(separator: "|", maxSplits: 1).last.map(String.init) ?? ev.id
                        var synced = t
                        synced.id = stableUUID("google:\(raw)")
                        synced.kind = "event"; synced.source = "google"; synced.googleEventID = raw
                        synced.sourceCalendar = ev.calendarID; synced.externalURL = ev.link?.absoluteString
                        store.upsert(synced)
                    } else {
                        // Repeating: Google holds the schedule; its dates arrive with the next import.
                        await model.importer.importNow(includeCalendly: false)
                    }
                    model.editingTask = nil
                } catch {
                    store.upsert(t)
                    self.error = "Saved in Cadence only — Google Calendar failed: \(error.localizedDescription)"
                }
                saving = false
            }
            return
        }

        store.upsert(t)
        guard addToGoogle else { model.editingTask = nil; return }
        saving = true
        Task {
            do {
                let start = t.timeMinutes.map { dayAt(t.startDate, minutes: $0) } ?? t.startDate
                let ev = try await google.create(NewGoogleEvent(
                    title: t.title, details: t.notes, start: start,
                    end: start.adding(minutes: t.durationMinutes), allDay: t.timeMinutes == nil,
                    rrule: t.recurrence.rrule(start: t.startDate), busy: t.isBusy))
                if var latest = store.task(t.id) {
                    latest.googleEventID = ev?.id
                    store.upsert(latest)
                }
                model.editingTask = nil
            } catch {
                self.error = "Saved in Cadence, but Google Calendar failed: \(error.localizedDescription)"
            }
            saving = false
        }
    }
}

struct WeekdayPicker: View {
    @Binding var selection: [Int]

    var body: some View {
        let cal = Calendar.current
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 + 1 }
        HStack(spacing: 6) {
            ForEach(order, id: \.self) { wd in
                let on = selection.contains(wd)
                Text(cal.veryShortWeekdaySymbols[wd - 1])
                    .font(.app(.callout).weight(.semibold))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(on ? .white : .primary)
                    .background(Circle().fill(on ? Color.accentColor : Color.secondary.opacity(0.15)))
                    .contentShape(Circle())
                    .onTapGesture {
                        if on { if selection.count > 1 { selection.removeAll { $0 == wd } } }
                        else { selection.append(wd); selection.sort() }
                    }
                    .help(cal.weekdaySymbols[wd - 1])
            }
            Spacer()
            Button("Weekdays") { selection = [2, 3, 4, 5, 6] }.controlSize(.small)
        }
    }
}
