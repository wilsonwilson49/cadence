import SwiftUI

struct MobileRoot: View {
    @EnvironmentObject private var model: MobileModel
    @EnvironmentObject private var store: Store

    var body: some View {
        TabView(selection: $model.tab) {
            TodayScreen().tabItem { Label("Today", systemImage: "sun.max") }.tag(0)
                .badge(store.remainingToday)
            HabitsScreen().tabItem { Label("Habits", systemImage: "arrow.triangle.2.circlepath") }.tag(1)
            WeekScreen().tabItem { Label("Week", systemImage: "calendar") }.tag(2)
            FocusScreen().tabItem { Label("Focus", systemImage: "scope") }.tag(3)
            MoreScreen().tabItem { Label("More", systemImage: "ellipsis.circle") }.tag(4)
        }
        .sheet(item: $model.reflecting) { ReflectionSheet(target: $0) }
        .sheet(item: $model.editing) { t in EditorSheet(task: t, isNew: store.task(t.id) == nil) }
        .onAppear { model.start() }
    }
}

/// "+" menu used on several screens.
struct NewMenu: View {
    @EnvironmentObject private var model: MobileModel
    var day = Date()
    var body: some View {
        Menu {
            Button { model.newTask(on: day) } label: { Label("New Task", systemImage: "checklist") }
            Button { model.newHabit() } label: { Label("New Habit", systemImage: "arrow.triangle.2.circlepath") }
            Button { model.newEvent(on: day) } label: { Label("New Event", systemImage: "calendar.badge.plus") }
        } label: { Image(systemName: "plus.circle.fill").font(.title3) }
    }
}

// MARK: - Today

struct TodayScreen: View {
    @EnvironmentObject private var model: MobileModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var sync: SyncService
    @State private var quick = ""

    var body: some View {
        let items = store.checklist(on: Date())
        let overdue = store.overdue()
        let all = overdue + items
        let tasks = items.filter { !$0.isHabit && !$0.isUntilDone }
        let habits = items.filter(\.isHabit)
        let ongoing = items.filter { !$0.isHabit && $0.isUntilDone }
        let events = store.events(on: Date())
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(greeting).foregroundStyle(.secondary)
                            Text(Date().formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.title2.bold())
                            Text(status(all)).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Ring(done: all.filter(\.isDone).count, total: all.count)
                    }
                    .padding(.vertical, 4)
                    HStack {
                        Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
                        TextField("Quick add to today", text: $quick).submitLabel(.done).onSubmit(addQuick)
                    }
                }
                if !sync.isSignedIn && !LaunchOptions.has("-demo") {
                    Section {
                        NavigationLink { AccountScreen() } label: {
                            Label("Sign in to sync with your Mac and the web", systemImage: "icloud.and.arrow.up").foregroundStyle(.orange)
                        }
                    }
                }
                if !overdue.isEmpty { Section("Overdue") { ForEach(overdue) { MobileRow(occ: $0) } } }
                Section {
                    if tasks.isEmpty { Text(ongoing.isEmpty && habits.isEmpty ? "Nothing scheduled for today." : "No other tasks today.").foregroundStyle(.secondary) }
                    ForEach(tasks) { MobileRow(occ: $0) }
                } header: { Text("Today's checklist") }
                if !habits.isEmpty {
                    Section { ForEach(habits) { MobileRow(occ: $0) } } header: {
                        Text("Habits · \(habits.filter { !$0.isResolved }.count) left")
                    }
                }
                if !ongoing.isEmpty {
                    Section { ForEach(ongoing) { MobileRow(occ: $0) } } header: { Text("Until done") } footer: {
                        Text("These stay on your list until you check them off or mark them “didn't do it”.")
                    }
                }
                Section("Schedule") {
                    if events.isEmpty { Text("No events today.").foregroundStyle(.secondary) }
                    ForEach(events) { MobileEventRow(occ: $0) }
                }
                Section {
                    Text("Checking an item off asks for a reflection of at least \(store.settings.minReflectionWords) words.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Today")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { NewMenu() } }
            .refreshable { sync.sync(manual: true) }
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h >= 5 && h < 12 ? "Good morning" : h >= 12 && h < 17 ? "Good afternoon" : "Good evening"
    }
    private func status(_ all: [Occurrence]) -> String {
        if all.isEmpty { return "A clear day." }
        let done = all.filter(\.isDone).count, settled = all.filter(\.isResolved).count
        if done == all.count { return "Everything is checked off. Nice work." }
        if settled == all.count { return "All settled: \(done) done, \(all.count - done) not done." }
        return "\(all.count - settled) of \(all.count) left to check off."
    }
    private func addQuick() {
        let t = quick.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var task = PlanTask(title: t, startDate: Date().startOfDay, channels: store.settings.defaultChannels)
        task.kind = "task"
        store.upsert(task)
        quick = ""
    }
}

// MARK: - Habits

struct HabitsScreen: View {
    @EnvironmentObject private var model: MobileModel
    @EnvironmentObject private var store: Store
    @AppStorage("habitTrackerDays") private var range = 7

    var body: some View {
        let habits = store.tasks.filter { $0.isHabit && $0.archived != true }.sorted { $0.title < $1.title }
        let stats = Dictionary(uniqueKeysWithValues: habits.map { ($0.id, $0.habitStats()) })
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if habits.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle").font(.system(size: 40)).foregroundStyle(.secondary)
                            Text("No habits yet").font(.title3.weight(.semibold))
                            Text("Start tiny: one thing you want to do every day, and its 2-minute version.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("New Habit") { model.newHabit() }.buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 60)
                    } else {
                        tracker(habits, stats)
                        ForEach(habits) { t in card(t, stats[t.id] ?? t.habitStats()) }
                    }
                }
                .padding()
            }
            .navigationTitle("Habits")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { model.newHabit() } label: { Image(systemName: "plus.circle.fill").font(.title3) } } }
        }
    }

    /// The tracker grid: a row per habit, a column per day (newest on the right).
    private func tracker(_ habits: [PlanTask], _ stats: [UUID: PlanTask.HabitStats]) -> some View {
        let days = (stats[habits[0].id]?.grid.suffix(range) ?? []).map(\.day)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tracker").font(.headline)
                Spacer()
                Picker("", selection: $range) { Text("Week").tag(7); Text("2 wks").tag(14); Text("Month").tag(30) }
                    .pickerStyle(.segmented).frame(width: 190)
            }
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    Color.clear.frame(width: 96, height: 30)
                    ForEach(habits) { t in
                        Text(t.title).font(.caption).lineLimit(1).frame(width: 96, height: 24, alignment: .leading)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            ForEach(days, id: \.self) { d in
                                VStack(spacing: 0) {
                                    Text(Calendar.current.veryShortWeekdaySymbols[Calendar.current.component(.weekday, from: d) - 1]).font(.system(size: 9)).foregroundStyle(.secondary)
                                    Text(d.formatted(.dateTime.day())).font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(d.isToday ? .white : .primary)
                                        .frame(width: 20, height: 16).background(Capsule().fill(d.isToday ? Color.pink : .clear))
                                }
                                .frame(width: 24, height: 30)
                            }
                        }
                        ForEach(habits) { t in
                            HStack(spacing: 4) {
                                ForEach(Array((stats[t.id]?.grid.suffix(range) ?? []).enumerated()), id: \.offset) { _, c in
                                    cell(t, c.day, c.state)
                                }
                            }
                        }
                    }
                }
                .defaultScrollAnchor(.trailing)
                VStack(spacing: 4) {
                    Image(systemName: "flame").font(.caption).foregroundStyle(.secondary).frame(height: 30)
                    ForEach(habits) { t in
                        Text("\(stats[t.id]?.streak ?? 0)").font(.caption.bold()).foregroundStyle(.orange).frame(height: 24)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }

    @ViewBuilder private func cell(_ t: PlanTask, _ day: Date, _ state: PlanTask.DayState) -> some View {
        let c = t.color.color
        RoundedRectangle(cornerRadius: 5)
            .fill(state == .done ? c : state == .missed ? Color.red.opacity(0.75) : state == .off ? Color.primary.opacity(0.04)
                  : state == .open || state == .lapsed ? Color.clear : Color.primary.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(state == .open ? c : state == .lapsed ? Color.red.opacity(0.45) : .clear, lineWidth: state == .open ? 2 : 1.5))
            .overlay {
                if state == .done { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                if state == .missed { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white) }
            }
            .frame(width: 24, height: 24)
            .onTapGesture { if state == .open || state == .lapsed { model.reflect(Occurrence(task: t, day: day)) } }
    }

    private func card(_ t: PlanTask, _ st: PlanTask.HabitStats) -> some View {
        let today = Date().startOfDay
        let occ = t.occurs(on: today) ? Occurrence(task: t, day: today) : nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 2).fill(t.color.color).frame(width: 4, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).font(.headline)
                    Text("\(t.planSummary ?? "Every day") · \((t.habit ?? HabitInfo()).styleLabel)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(spacing: 0) {
                    Image(systemName: "flame.fill").foregroundStyle(.orange).font(.caption)
                    Text("\(st.streak)").font(.title3.bold())
                    Text("best \(st.best)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if let s = t.habitSentence { Text(s).font(.callout).italic().foregroundStyle(.secondary) }
            HStack(spacing: 12) {
                Text(st.rate.map { "\($0)% kept" } ?? "New")
                Text("\(st.votes) vote\(st.votes == 1 ? "" : "s")")
                if let two = t.habit?.twoMinute { Label(two, systemImage: "timer").lineLimit(1) }
            }
            .font(.caption).foregroundStyle(.secondary)
            if st.missTwice {
                Label("Missed last time. Never miss twice: even the 2-minute version counts.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                if let occ, !occ.isResolved {
                    Button { model.reflect(occ) } label: { Label("Done today…", systemImage: "checkmark") }.buttonStyle(.borderedProminent)
                    Button { model.reflect(occ, missed: true) } label: { Label("Didn't do it…", systemImage: "xmark") }.buttonStyle(.bordered)
                } else if occ?.isDone == true {
                    Label("Done today", systemImage: "checkmark").font(.callout).foregroundStyle(.green)
                } else if occ?.isMissed == true {
                    Label("Not done today", systemImage: "xmark").font(.callout).foregroundStyle(.red)
                }
                Spacer()
                Button("Edit") { model.editing = t }.font(.callout)
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
    }
}

// MARK: - Week

struct WeekScreen: View {
    @EnvironmentObject private var model: MobileModel
    @EnvironmentObject private var store: Store
    @State private var start = Date().startOfWeek

    var body: some View {
        NavigationStack {
            List {
                ForEach(0..<7, id: \.self) { i in
                    let day = start.adding(days: i)
                    let occs = store.occurrences(on: day)
                    Section {
                        if occs.isEmpty { Text("Nothing planned").foregroundStyle(.secondary).font(.callout) }
                        ForEach(occs.filter { !$0.isEvent }) { MobileRow(occ: $0, inDayList: true) }
                        ForEach(occs.filter(\.isEvent)) { MobileEventRow(occ: $0) }
                    } header: {
                        HStack {
                            Text(day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())).foregroundStyle(day.isToday ? Color.pink : .secondary)
                            if day.isToday { Text("Today").font(.caption2.bold()).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Color.pink)) }
                        }
                    }
                }
            }
            .navigationTitle(weekTitle)
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { start = start.adding(days: -7) } label: { Image(systemName: "chevron.left") }
                    Button("Today") { start = Date().startOfWeek }
                    Button { start = start.adding(days: 7) } label: { Image(systemName: "chevron.right") }
                }
                ToolbarItem(placement: .topBarTrailing) { NewMenu(day: start) }
            }
        }
    }

    private var weekTitle: String {
        let end = start.adding(days: 6)
        return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
    }
}

// MARK: - Focus

struct FocusScreen: View {
    @EnvironmentObject private var model: MobileModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var focus: MobileFocus
    @State private var minutes = 25
    @State private var picks: Set<String>?

    var body: some View {
        let sessions = store.sortedFocusSessions
        let points = sessions.reduce(0) { $0 + $1.points }
        let lv = Focus.level(points: points)
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Text("\(lv.level)").font(.title.weight(.heavy)).foregroundStyle(.white).frame(width: 50, height: 50)
                            .background(RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Level \(lv.level) · \(points) points").font(.headline)
                            ProgressView(value: Double(lv.into), total: Double(lv.span)).tint(.pink)
                            Text("\(Focus.streak(sessions))-day streak · \(lv.span - lv.into) to level \(lv.level + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if focus.running { running } else { setup }
                if !sessions.isEmpty {
                    Section("Recent sessions") {
                        ForEach(sessions.prefix(8)) { s in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(s.finished) of \(s.picked) done in \(s.actualMinutes) min")
                                    Text("\(s.startedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())) · \(s.focusPercent)% focused · \(s.device == "ios" ? "iPhone" : s.device == "mac" ? "Mac" : "Web")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("+\(s.points)").bold().foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Focus")
            .onAppear { minutes = store.settings.focusMinutes }
        }
    }

    @ViewBuilder private var running: some View {
        let occs = focus.picked.compactMap(model.occurrence)
        let frac = Double(focus.secondsLeft) / Double(max(1, focus.minutes * 60))
        Section {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 14)
                Circle().trim(from: 0, to: frac).stroke(focus.secondsLeft < 300 ? Color.orange : .pink, style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90)).animation(.linear(duration: 1), value: frac)
                VStack {
                    Text(focus.clock).font(.system(size: 48, weight: .bold).monospacedDigit())
                    Text("\(focus.finished.count) of \(occs.count) done").foregroundStyle(.secondary)
                }
            }
            .frame(height: 240).padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
        Section {
            ForEach(occs) { o in
                let on = focus.finished.contains(o.id)
                Button { focus.toggleFinished(o.id) } label: {
                    HStack {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? o.task.color.color : .secondary).font(.title3)
                        Text(o.task.title).strikethrough(on).foregroundStyle(on ? .secondary : .primary)
                        Spacer()
                        Text(o.isHabit ? "Habit" : "Task").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } footer: { Text("Tick each as you finish. You'll write the reflections when time's up. Leaving Cadence counts as time away.") }
        Section {
            Button { focus.addFiveMinutes() } label: { Label("Add 5 minutes", systemImage: "plus") }
            Button("End now", role: .destructive) { focus.end() }
        }
    }

    @ViewBuilder private var setup: some View {
        let open = store.todayChecklist().filter { !$0.isResolved }
        let selected = picks ?? Set(open.map(\.id))
        if let r = focus.result {
            let unreflected = r.finishedIds.compactMap(model.occurrence).filter { !$0.isResolved }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Time! \(r.finished) of \(r.picked) done").font(.headline)
                    Text("\(r.focusPercent)% focused · +\(r.points) points").foregroundStyle(.secondary)
                }
                ForEach(unreflected) { o in
                    HStack { Text(o.task.title); Spacer(); Button("Reflect & check off") { model.reflect(o) }.buttonStyle(.borderedProminent).controlSize(.small) }
                }
                Button("Dismiss") { focus.result = nil }
            }
        }
        Section("How long?") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach([10, 15, 25, 45, 60], id: \.self) { m in
                        Button("\(m) min") { minutes = m }.buttonStyle(.bordered).tint(minutes == m ? .pink : .gray)
                    }
                }
            }
            Stepper("\(minutes) minutes", value: $minutes, in: 1...240)
        }
        Section("What will you get through?") {
            if open.isEmpty { Text("Nothing open on today's list.").foregroundStyle(.secondary) }
            ForEach(open) { o in
                Button {
                    var s = selected
                    if s.contains(o.id) { s.remove(o.id) } else { s.insert(o.id) }
                    picks = s
                } label: {
                    HStack {
                        Image(systemName: selected.contains(o.id) ? "checkmark.square.fill" : "square").foregroundStyle(selected.contains(o.id) ? Color.pink : .secondary)
                        Text(o.task.title).foregroundStyle(.primary)
                        Spacer()
                        Text(o.isHabit ? "habit" : o.isUntilDone ? "until done" : "today").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        Section {
            Button {
                if minutes != store.settings.focusMinutes { store.settings.focusMinutes = minutes }
                focus.start(minutes: minutes, picked: open.map(\.id).filter(selected.contains))
                picks = nil
            } label: { Label("Start \(minutes)-minute focus", systemImage: "scope").frame(maxWidth: .infinity) }
            .buttonStyle(.borderedProminent).disabled(selected.isEmpty)
            .listRowBackground(Color.clear)
        } footer: {
            Text("10 points per item finished in time, ×1.5 if you stay 90% focused (×1.25 at 75%), +20 for clearing the list.")
        }
    }
}

// MARK: - More

struct MoreScreen: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var sync: SyncService

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { TodoScreen() } label: { Label("To-Do List", systemImage: "checklist") }
                    NavigationLink { ReflectionsScreen() } label: { Label("Reflections", systemImage: "text.quote").badge(store.reflections.count) }
                }
                Section {
                    NavigationLink { AccountScreen() } label: {
                        Label(sync.isSignedIn ? "Account · \(sync.username ?? "")" : "Sign in to sync", systemImage: "person.crop.circle")
                    }
                    NavigationLink { SettingsScreen() } label: { Label("Settings", systemImage: "gearshape") }
                }
                Section {
                    Link(destination: URL(string: "\(SyncService.defaultServer)/privacy")!) { Label("Privacy Policy", systemImage: "hand.raised") }
                    Link(destination: URL(string: "\(SyncService.defaultServer)/terms")!) { Label("Terms of Service", systemImage: "doc.text") }
                    Link(destination: URL(string: "mailto:cadencemain26@gmail.com")!) { Label("Contact", systemImage: "envelope") }
                } footer: {
                    Text("Cadence \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                }
            }
            .navigationTitle("More")
        }
    }
}

struct TodoScreen: View {
    @EnvironmentObject private var store: Store
    var body: some View {
        let today = Date().startOfDay
        let ongoing = store.checklist(on: today).filter { !$0.isHabit && $0.isUntilDone && !$0.isResolved }
        List {
            let overdue = store.overdue()
            if !overdue.isEmpty { Section("Overdue") { ForEach(overdue) { MobileRow(occ: $0, showDate: true) } } }
            if !ongoing.isEmpty { Section("Until done") { ForEach(ongoing) { MobileRow(occ: $0) } } }
            ForEach(0..<14, id: \.self) { i in
                let day = today.adding(days: i)
                let items = store.checklist(on: day).filter { o in !o.isHabit && !o.isResolved
                    && (!o.isUntilDone || (!day.isToday && o.task.repStart(on: day).map { $0.isSameDay(day) } == true)) }
                if !items.isEmpty {
                    Section(day.isToday ? "Today" : day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())) {
                        ForEach(items) { MobileRow(occ: $0) }
                    }
                }
            }
        }
        .navigationTitle("To-Do List")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { NewMenu() } }
    }
}

struct ReflectionsScreen: View {
    @EnvironmentObject private var store: Store
    @State private var search = ""
    var body: some View {
        let list = store.reflections.filter { search.isEmpty || $0.text.localizedCaseInsensitiveContains(search) || $0.taskTitle.localizedCaseInsensitiveContains(search) }
            .sorted { $0.createdAt > $1.createdAt }
        List {
            if list.isEmpty { Text("Each time you check something off you write a short reflection. They collect here.").foregroundStyle(.secondary) }
            ForEach(list) { r in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(r.taskTitle).font(.headline).lineLimit(1)
                        Text(r.isMissed ? "Didn't do it" : "Done").font(.caption2.bold()).foregroundStyle(r.isMissed ? .red : .green)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill((r.isMissed ? Color.red : .green).opacity(0.14)))
                        Spacer()
                        Text(r.createdAt.formatted(.dateTime.month(.abbreviated).day())).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(r.text).font(.callout)
                }
                .padding(.vertical, 4)
            }
        }
        .searchable(text: $search)
        .navigationTitle("Reflections")
    }
}

struct SettingsScreen: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var model: MobileModel
    var body: some View {
        Form {
            Section {
                Toggle("Morning check-in notification (8:30)", isOn: $store.settings.checkInOnLaunch)
                Picker("Remind me about tasks without a time at", selection: $store.settings.untimedReminderMinutes) {
                    ForEach(Array(stride(from: 6 * 60, through: 12 * 60, by: 30)), id: \.self) { Text(timeString(minutes: $0)).tag($0) }
                }
            } header: { Text("Reminders") } footer: {
                Text(model.notificationsAllowed ? "Reminders come as notifications, planned ahead for the next few days."
                     : "Notifications are off for Cadence. Turn them on in the Settings app › Notifications › Cadence.")
            }
            Section {
                Stepper("At least \(store.settings.minReflectionWords) words", value: $store.settings.minReflectionWords, in: 20...200, step: 5)
            } header: { Text("Reflections") } footer: { Text("Every check-off needs a reflection. The minimum can't go below 20 words.") }
            Section {
                Text("Google Calendar, Calendly, Google Tasks, booking and screen time are set up on the Mac app or the website; what they bring in syncs here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}

struct AccountScreen: View {
    @EnvironmentObject private var sync: SyncService
    @State private var username = ""
    @State private var password = ""
    @State private var creating = false
    @State private var confirmDelete = false
    @State private var deletePassword = ""
    @State private var deleteError: String?
    @State private var deleting = false

    var body: some View {
        Form {
            if sync.isSignedIn {
                Section {
                    LabeledContent("Signed in as", value: sync.username ?? "")
                    LabeledContent("Last synced", value: sync.lastSynced.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                    Button("Sync now") { sync.sync(manual: true) }
                    Button("Sign out") { sync.signOut() }
                } footer: { Text("Your checklist, habits, reflections and focus sessions sync with the Mac app and \(SyncService.defaultServer.replacingOccurrences(of: "https://", with: "")).") }
                Section {
                    Button("Delete account…", role: .destructive) { confirmDelete = true }
                } footer: { Text("Permanently erases your Cadence account and everything stored with it on our servers, and disconnects Google and Calendly.") }
            } else {
                Section {
                    Picker("", selection: $creating) { Text("Sign in").tag(false); Text("Create account").tag(true) }.pickerStyle(.segmented)
                    TextField("Username", text: $username).textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password).textContentType(creating ? .newPassword : .password)
                    Button(creating ? "Create account" : "Sign in") {
                        Task { await sync.signIn(username: username, password: password, create: creating) }
                    }
                    .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || sync.isSigningIn)
                    if case .error(let msg) = sync.status { Text(msg).foregroundStyle(.red).font(.footnote) }
                } footer: {
                    Text("Use the same account as the Mac app and the website. You can also use Cadence on this iPhone without an account; it just won't sync.")
                }
            }
        }
        .navigationTitle("Account")
        .alert("Delete your account?", isPresented: $confirmDelete) {
            SecureField("Password", text: $deletePassword)
            Button("Cancel", role: .cancel) { deletePassword = "" }
            Button("Delete", role: .destructive) {
                Task {
                    do { try await sync.deleteAccount(password: deletePassword); deleteError = nil }
                    catch { deleteError = error.localizedDescription }
                    deletePassword = ""
                }
            }
        } message: { Text("This can't be undone. Enter your password to confirm.") }
        .alert("Couldn't delete the account", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(deleteError ?? "") }
    }
}
