import SwiftUI
import AppKit

/// Time pressure: set a time, pick what you'll get through, and score what you finish before it runs out.
struct FocusView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var focus: FocusEngine
    @State private var minutes = 25
    @State private var picks: Set<String>?
    @State private var didAppear = false
    /// "work" (one task, until it's done) or "sprint" (race the clock through a list).
    @AppStorage("focusMode") private var modeRaw = "work"
    @State private var newWork = ""

    var body: some View {
        let sessions = store.sortedFocusSessions
        let points = sessions.reduce(0) { $0 + $1.points }
        let lv = Focus.level(points: points)
        VStack(spacing: 0) {
            ScreenHeader(title: "Focus", subtitle: modeRaw == "work" || focus.isWorking
                         ? "Work on one thing: pick it, and it stays up front with distractions blocked until you complete it."
                         : "Race the clock: set a time, then see how much of your list you can finish before it runs out.") { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if focus.isWorking { working } else {
                        levelCard(lv, points: points, sessions: sessions)
                        if focus.running { running } else {
                            Picker("", selection: $modeRaw) {
                                Label("Work on one task", systemImage: "scope").tag("work")
                                Label("Sprint through a list", systemImage: "timer").tag("sprint")
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                            if modeRaw == "work" { workSetup } else { setup }
                        }
                    }
                    if !sessions.isEmpty { history(sessions) }
                }
                .padding(22)
                .frame(maxWidth: 980, alignment: .leading)
            }
        }
        .onAppear { if !didAppear { didAppear = true; minutes = store.settings.focusMinutes } }
    }

    private func levelCard(_ lv: (level: Int, into: Int, span: Int), points: Int, sessions: [FocusSession]) -> some View {
        let week = sessions.filter { $0.startedAt >= Date().startOfWeek }.reduce(0) { $0 + $1.points }
        return HStack(spacing: 14) {
            Text("\(lv.level)").font(.system(size: 24, weight: .heavy)).foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.solid))
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Level \(lv.level)").font(.app(.headline))
                    Spacer()
                    Text("\(points) points · \(lv.span - lv.into) to level \(lv.level + 1)").font(.app(.caption)).foregroundStyle(.secondary)
                }
                ProgressView(value: Double(lv.into), total: Double(lv.span)).tint(Theme.accent)
                Text("\(Focus.streak(sessions))-day focus streak · \(week) points this week · best session: \(sessions.map(\.finished).max() ?? 0) done")
                    .font(.app(.caption)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var running: some View {
        let occs = focus.picked.compactMap(focus.occurrence)
        let frac = Double(focus.secondsLeft) / Double(max(1, focus.minutes * 60))
        let final = focus.secondsLeft < 300
        return HStack(alignment: .top, spacing: 24) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 12)
                Circle().trim(from: 0, to: frac).stroke(final ? Color.orange : Theme.accent, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90)).animation(.linear(duration: 1), value: frac)
                VStack(spacing: 2) {
                    Text(focus.clock).font(.system(size: 44, weight: .bold).monospacedDigit()).foregroundStyle(final ? Color.orange : .primary)
                    Text("\(focus.finished.count) of \(occs.count) done").font(.app(.caption)).foregroundStyle(.secondary)
                    if focus.distractingSeconds + focus.awaySeconds > 0 {
                        Text("\(durationString(seconds: focus.distractingSeconds)) distracted").font(.app(.caption2)).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 230, height: 230)
            VStack(alignment: .leading, spacing: 10) {
                Text("Tick each one as you finish it. You'll write the reflections when time's up, so the clock is only for doing. Switching to a distracting app counts against your focus.")
                    .font(.app(.caption)).foregroundStyle(.secondary)
                Card {
                    VStack(spacing: 0) {
                        ForEach(occs) { o in
                            let on = focus.finished.contains(o.id)
                            HStack(spacing: 10) {
                                CheckButton(done: on, color: o.task.color.color) { focus.toggleFinished(o.id) }
                                Text(o.task.title).strikethrough(on).foregroundStyle(on ? .secondary : .primary)
                                Spacer()
                                Text(o.isHabit ? "Habit" : "Task").font(.app(.caption)).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                HStack {
                    Button { focus.addFiveMinutes() } label: { Label("5 minutes", systemImage: "plus") }
                    Spacer()
                    Button("End now", role: .destructive) { focus.end() }
                }
            }
        }
    }

    private var openItems: [Occurrence] { store.todayChecklist().filter { !$0.isResolved } }

    // MARK: Work mode

    /// Today's open items, most important first (then in checklist order).
    private var workChoices: [Occurrence] {
        openItems.filter { !$0.isEvent }.enumerated()
            .sorted { ($0.element.task.priorityLevel?.rank ?? 3, $0.offset) < ($1.element.task.priorityLevel?.rank ?? 3, $1.offset) }
            .map(\.element)
    }

    private var workSetup: some View {
        let choices = workChoices
        return VStack(alignment: .leading, spacing: 14) {
            if let r = focus.result { result(r) }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle(text: "What are you working on?", symbol: "scope")
                    Text("Click one and it starts straight away: it goes up front as your headline, the clock runs, and distracting apps and websites (Settings › Tough love) are blocked until you complete it or stop.")
                        .font(.app(.caption)).foregroundStyle(.secondary)
                    HStack {
                        TextField("Something else? Type it and press Return", text: $newWork).onSubmit(startNewWork)
                        Button("Start", action: startNewWork).disabled(newWork.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    Toggle("Block distracting apps and websites while I work", isOn: $focus.workBlocks)
                    if choices.isEmpty {
                        Text("Nothing open on today's list.").foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(choices) { o in WorkPickRow(occ: o) { focus.startWork(o) } }
                        }
                    }
                }
            }
        }
    }

    /// "Something else": makes it a task for today (quiet, no reminders) and starts on it.
    private func startNewWork() {
        let title = newWork.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var t = PlanTask(title: title, startDate: Date().startOfDay)
        t.kind = "task"
        t.channels = []
        store.upsert(t)
        newWork = ""
        focus.startWork(Occurrence(task: t, day: Date().startOfDay))
    }

    /// Work mode: the task as a headline, the clock counting up, and Complete.
    @ViewBuilder private var working: some View {
        if let o = focus.workOccurrence {
            let t = o.task
            let target = t.typicalMinutes ?? (t.timeMinutes != nil ? t.durationMinutes : nil)
            VStack(alignment: .leading, spacing: 16) {
                Text("NOW WORKING ON").font(.app(.caption).weight(.bold)).tracking(1.2).foregroundStyle(.secondary)
                Text(t.title)
                    .font(Theme.heading(36, .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 14) {
                    if let p = t.priorityLevel { Label("\(p.title) priority", systemImage: p.symbol).foregroundStyle(p.color) }
                    if let h = t.hardnessLevel {
                        HStack(spacing: 5) { HardnessMeter(level: h, height: 11); Text(Hardness.title(h)) }
                    }
                    if let m = t.typicalMinutes { Label("usually \(TaskStats.format(m))", systemImage: "stopwatch") }
                    if o.isOverdue { Text("Overdue").foregroundStyle(.red) }
                    if t.isPastDue { Text("Past due").foregroundStyle(.red) }
                }
                .font(.app(.callout)).foregroundStyle(.secondary).labelStyle(CompactLabelStyle())
                if !t.notes.isEmpty {
                    Text(t.notes).font(.app(.body)).foregroundStyle(.secondary).lineLimit(6).textSelection(.enabled)
                }
                if t.hasSteps { StepChecklist(occ: o) { _ in focus.completeWork() } }

                HStack(alignment: .center, spacing: 28) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(focus.clock).font(.system(size: 54, weight: .bold).monospacedDigit())
                        Text("\(focus.focusPercent)% focused" + (focus.distractingSeconds + focus.awaySeconds > 0
                             ? " · \(durationString(seconds: focus.distractingSeconds + focus.awaySeconds)) away or distracted" : ""))
                            .font(.app(.caption)).foregroundStyle(.secondary)
                    }
                    if let target {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: Double(min(focus.elapsedSeconds, target * 60)), total: Double(target * 60))
                                .tint(focus.elapsedSeconds > target * 60 ? .orange : Theme.accent)
                            Text(focus.elapsedSeconds > target * 60 ? "Past the \(TaskStats.format(target)) it usually takes"
                                 : "\(TaskStats.format(max(1, target - focus.elapsedSeconds / 60))) to the usual \(TaskStats.format(target))")
                                .font(.app(.caption)).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 320)
                    }
                }

                Label(model.nag.blocker.isOn ? "Distracting apps and websites are blocked \(model.nag.blocker.reason ?? "")."
                      : focus.workBlocks ? "Add distracting apps and websites in Settings › Tough love to have them blocked."
                      : "Blocking is off for this session.",
                      systemImage: model.nag.blocker.isOn ? "lock.fill" : "lock.open")
                    .font(.app(.caption)).foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button { focus.completeWork() } label: { Label("Complete", systemImage: "checkmark").padding(.horizontal, 8) }
                        .buttonStyle(.borderedProminent).controlSize(.large).tint(.green)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Check it off (⌘↩): you'll write the reflection, with the time already filled in")
                    let others = workChoices.filter { $0.id != o.id }
                    Menu {
                        ForEach(others) { x in Button(x.task.title) { focus.startWork(x) } }
                    } label: { Label("Switch task", systemImage: "arrow.left.arrow.right") }
                    .fixedSize().controlSize(.large).disabled(others.isEmpty)
                    Toggle("Block distractions", isOn: $focus.workBlocks).toggleStyle(.checkbox)
                    Spacer()
                    Button("Stop", role: .destructive) { focus.end(quiet: true) }.controlSize(.large)
                        .help("Stop working on it without checking it off (the time is still logged)")
                }
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(alignment: .leading) { Rectangle().fill(t.color.color).frame(width: 4) }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
    }

    private var setup: some View {
        let open = openItems
        let selected = picks ?? Set(open.map(\.id))
        return VStack(alignment: .leading, spacing: 14) {
            if let r = focus.result { result(r) }
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(text: "How long?", symbol: "timer")
                    FocusLengthPicker(minutes: $minutes)
                    SectionTitle(text: "What will you get through?", symbol: "checklist", count: selected.count)
                    if open.isEmpty {
                        Text("Nothing open on today's list. Add a task first.").foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), alignment: .leading)], alignment: .leading, spacing: 6) {
                            ForEach(open) { o in
                                Toggle(isOn: Binding(get: { selected.contains(o.id) }, set: { on in
                                    var s = selected
                                    if on { s.insert(o.id) } else { s.remove(o.id) }
                                    picks = s
                                })) {
                                    HStack {
                                        Text(o.task.title).lineLimit(1)
                                        Text(o.isHabit ? "habit" : o.isUntilDone ? "until done" : "today").font(.app(.caption2)).foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                    HStack {
                        Text("Score: 10 points per task finished in time, ×1.5 if you stay 90% focused (×1.25 at 75%), +20 for clearing the list.")
                            .font(.app(.caption)).foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            if minutes != store.settings.focusMinutes { store.settings.focusMinutes = minutes }
                            focus.start(minutes: minutes, picked: open.map(\.id).filter(selected.contains))
                            picks = nil
                        } label: { Label("Start \(Focus.label(minutes)) focus", systemImage: "scope") }
                        .buttonStyle(.borderedProminent).tint(Theme.solid)
                        .disabled(selected.isEmpty)
                    }
                }
            }
        }
    }

    private func result(_ r: FocusSession) -> some View {
        let unreflected = r.finishedIds.compactMap(focus.occurrence).filter { !$0.isResolved }
        return HStack(alignment: .top, spacing: 16) {
            Text("\(r.finished)").font(.system(size: 44, weight: .heavy).monospacedDigit()).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(r.isWork ? "\(r.finished > 0 ? "Done" : "Stopped"): \(r.title ?? "work") after \(Focus.label(max(1, r.actualMinutes)))"
                              : "Time! \(r.finished) of \(r.picked) done in \(r.actualMinutes) min").font(.app(.headline))
                Text("\(r.focusPercent)% focused (\(durationString(seconds: r.distractingSeconds + r.awaySeconds)) away or distracted) · ×\(String(format: "%g", Focus.multiplier(r.focusPercent))) · +\(r.points) points")
                    .font(.app(.caption)).foregroundStyle(.secondary)
                if !unreflected.isEmpty {
                    Text("Write a reflection for each to check it off:").font(.app(.caption)).padding(.top, 6)
                    ForEach(unreflected) { o in
                        HStack {
                            Text(o.task.title).lineLimit(1)
                            Spacer()
                            Button("Reflect & check off") { model.beginReflection(o) }.controlSize(.small).buttonStyle(.borderedProminent)
                        }
                    }
                } else if r.finished > 0 {
                    Label("All reflected and checked off.", systemImage: "checkmark").font(.app(.caption)).foregroundStyle(.green)
                }
            }
            Spacer()
            Button { focus.result = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.accent.opacity(0.3)))
    }

    private func history(_ sessions: [FocusSession]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Recent sessions", symbol: "clock")
            Card {
                VStack(spacing: 0) {
                    ForEach(sessions.prefix(8)) { s in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(s.startedAt.formatted(.dateTime.month(.abbreviated).day())).font(.app(.callout).monospacedDigit())
                                Text(timeString(s.startedAt)).font(.app(.caption)).foregroundStyle(.secondary)
                            }
                            .frame(width: 64, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.isWork ? "\(s.finished > 0 ? "Finished" : "Worked on") “\(s.title ?? "a task")” for \(Focus.label(max(1, s.actualMinutes)))"
                                              : "\(s.finished) of \(s.picked) done in \(s.actualMinutes) min").lineLimit(1)
                                Text("\(s.focusPercent)% focused\(s.distractingSeconds > 0 ? " · \(durationString(seconds: s.distractingSeconds)) in distracting apps" : "") · \(s.device == "mac" ? "Mac" : "Web")")
                                    .font(.app(.caption)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("+\(s.points)").font(.app(.headline)).foregroundStyle(.green)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }
}

/// Screen time on this Mac (opt-in), plus the daily totals other devices synced, and the focus settings.
struct ScreenTimeView: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var screenTime: ScreenTimeTracker
    @State private var newApp = ""

    /// Per-app seconds for a day across devices; today uses this Mac's live numbers.
    private func apps(on day: Date) -> [(name: String, seconds: Int)] {
        var m: [String: Int] = [:]
        for d in store.screenDays(on: day) { for a in d.apps { m[a.name, default: 0] += a.seconds } }
        if day.isToday { for (k, v) in screenTime.today { m[k] = max(m[k] ?? 0, v) } }
        return m.map { ($0.key, $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    var body: some View {
        let todayApps = apps(on: Date())
        let total = todayApps.reduce(0) { $0 + $1.seconds }
        let distracting = todayApps.filter { screenTime.isDistracting($0.name) }.reduce(0) { $0 + $1.seconds }
        let days = (0..<7).map { Date().startOfDay.adding(days: $0 - 6) }
        let week = days.map { d -> (Date, Int, Int) in
            let a = apps(on: d)
            return (d, a.reduce(0) { $0 + $1.seconds }, a.filter { screenTime.isDistracting($0.name) }.reduce(0) { $0 + $1.seconds })
        }
        let maxDay = max(1, week.map(\.1).max() ?? 1)
        let s = store.settings
        let focusToday = store.focusSessions.filter { $0.startedAt.isToday }.reduce(0) { $0 + $1.actualMinutes * 60 }
        return VStack(spacing: 0) {
            ScreenHeader(title: "Screen Time", subtitle: "Where your computer time goes, so focus time and habits can use it.") {
                Toggle("Track on this Mac", isOn: $screenTime.enabled).toggleStyle(.switch)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !screenTime.enabled {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer").font(.app(.title2)).foregroundStyle(.cyan)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Turn on screen time").font(.app(.callout).weight(.semibold))
                                Text("Cadence notes which app is in front while you're using your Mac (not when it's idle, locked or asleep) and keeps a daily total per app. Only those totals sync to your account; nothing else about what you do is recorded.")
                                    .font(.app(.caption)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Turn On") { screenTime.enabled = true }.buttonStyle(.borderedProminent)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.cyan.opacity(0.1)))
                    }
                    HStack(spacing: 12) {
                        tile(total > 0 ? durationString(seconds: total) : "—", "today\(s.screenLimitMinutes > 0 ? " · limit \(durationString(seconds: s.screenLimitMinutes * 60))" : "")",
                             "desktopcomputer", .cyan, over: s.screenLimitMinutes > 0 && total > s.screenLimitMinutes * 60)
                        tile(total > 0 ? durationString(seconds: distracting) : "—", "distracting\(s.distractingLimitMinutes > 0 ? " · limit \(durationString(seconds: s.distractingLimitMinutes * 60))" : "")",
                             "exclamationmark.triangle", .red, over: s.distractingLimitMinutes > 0 && distracting > s.distractingLimitMinutes * 60)
                        tile(durationString(seconds: focusToday), "in focus sessions today", "scope", .green)
                        let tracked = week.filter { $0.1 > 0 }
                        tile(tracked.isEmpty ? "—" : durationString(seconds: tracked.reduce(0) { $0 + $1.1 } / tracked.count), "daily average (7 days)", "calendar", .indigo)
                    }
                    if week.contains(where: { $0.1 > 0 }) {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionTitle(text: "Last 7 days", symbol: "calendar")
                                HStack(alignment: .bottom, spacing: 10) {
                                    ForEach(week, id: \.0) { d, t, dis in
                                        VStack(spacing: 4) {
                                            ZStack(alignment: .bottom) {
                                                RoundedRectangle(cornerRadius: 5).fill(Color.cyan.opacity(0.5))
                                                    .frame(height: max(2, 140 * CGFloat(t) / CGFloat(maxDay)))
                                                RoundedRectangle(cornerRadius: 5).fill(Color.red)
                                                    .frame(height: t > 0 ? 140 * CGFloat(dis) / CGFloat(maxDay) : 0)
                                            }
                                            .frame(height: 140, alignment: .bottom)
                                            Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.app(.caption2)).foregroundStyle(.secondary)
                                            Text(t > 0 ? durationString(seconds: t) : "").font(.app(.caption2))
                                        }
                                        .frame(maxWidth: .infinity)
                                        .help("\(durationString(seconds: t)) (\(durationString(seconds: dis)) distracting)")
                                    }
                                }
                            }
                        }
                    }
                    if !todayApps.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline) {
                                    SectionTitle(text: "Today by app", symbol: "list.bullet")
                                    Text("click one to mark it distracting").font(.app(.caption)).foregroundStyle(.secondary)
                                }
                                ForEach(todayApps.prefix(12), id: \.name) { a in
                                    let dis = screenTime.isDistracting(a.name)
                                    Button { toggleDistracting(a.name) } label: {
                                        HStack(spacing: 10) {
                                            Text(a.name).lineLimit(1).frame(width: 170, alignment: .leading)
                                            GeometryReader { g in
                                                ZStack(alignment: .leading) {
                                                    Capsule().fill(Color.primary.opacity(0.07))
                                                    Capsule().fill(dis ? Color.red : .cyan)
                                                        .frame(width: g.size.width * CGFloat(a.seconds) / CGFloat(max(1, todayApps[0].seconds)))
                                                }
                                            }
                                            .frame(height: 8)
                                            Text(durationString(seconds: a.seconds)).font(.app(.caption).monospacedDigit()).frame(width: 60, alignment: .trailing)
                                            Text("distracting").font(.app(.caption2)).foregroundStyle(.red).opacity(dis ? 1 : 0)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(dis ? "Distracting: click to unmark" : "Click to mark as distracting")
                                }
                            }
                        }
                    }
                    settings
                }
                .padding(22)
                .frame(maxWidth: 980, alignment: .leading)
            }
        }
    }

    private func tile(_ value: String, _ label: String, _ symbol: String, _ tint: Color, over: Bool = false) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.app(.title3)).foregroundStyle(tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.app(.title3).bold()).monospacedDigit().foregroundStyle(over ? Color.red : .primary)
                Text(label).font(.app(.caption)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.08)))
    }

    private func toggleDistracting(_ app: String) {
        var list = store.settings.distractingApps
        if let i = list.firstIndex(where: { $0.lowercased() == app.lowercased() }) { list.remove(at: i) } else { list.append(app) }
        store.settings.distractingApps = list
    }

    private var runningApps: [String] {
        let names = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
        return Array(Set(names)).filter { n in !store.settings.distractingApps.contains { $0.lowercased() == n.lowercased() } && n != "Cadence" }.sorted()
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Focus settings", symbol: "slider.horizontal.3")
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    limitPicker("Daily screen-time limit", $store.settings.screenLimitMinutes, note: "Cadence nudges you once you go past it.")
                    limitPicker("Daily limit for distracting apps", $store.settings.distractingLimitMinutes)
                    Divider()
                    Text("Distracting apps").font(.app(.callout).weight(.medium))
                    Text("During a focus session, Cadence nudges you back when one of these comes to the front, and time in them lowers your focus score.")
                        .font(.app(.caption)).foregroundStyle(.secondary)
                    FlowRow(store.settings.distractingApps.map { app in
                        AnyView(HStack(spacing: 4) {
                            Text(app)
                            Button { toggleDistracting(app) } label: { Image(systemName: "xmark").font(.app(.caption2)) }.buttonStyle(.borderless)
                        }
                        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Color.red.opacity(0.12))))
                    })
                    HStack {
                        TextField("App name, e.g. YouTube", text: $newApp).frame(width: 220).onSubmit(addApp)
                        Button("Add", action: addApp).disabled(newApp.trimmingCharacters(in: .whitespaces).isEmpty)
                        Menu("From open apps") {
                            ForEach(runningApps, id: \.self) { n in Button(n) { toggleDistracting(n) } }
                        }
                        .fixedSize()
                    }
                }
            }
        }
    }

    private func addApp() {
        let a = newApp.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty else { return }
        if !store.settings.distractingApps.contains(where: { $0.lowercased() == a.lowercased() }) { store.settings.distractingApps.append(a) }
        newApp = ""
    }

    private func limitPicker(_ title: String, _ value: Binding<Int>, note: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let note { Text(note).font(.app(.caption)).foregroundStyle(.secondary) }
            }
            Spacer()
            Picker("", selection: value) {
                ForEach([0, 30, 60, 90, 120, 180, 240, 360, 480], id: \.self) { m in
                    Text(m == 0 ? "Off" : durationString(seconds: m * 60)).tag(m)
                }
            }
            .labelsHidden().fixedSize()
        }
    }
}

/// The length buttons (your saved lengths) plus a box to type any length, which you can save as a button.
/// Right-click a button to remove it.
struct FocusLengthPicker: View {
    @EnvironmentObject private var store: Store
    @Binding var minutes: Int
    @State private var text = ""
    @FocusState private var typing: Bool

    var body: some View {
        let lengths = store.settings.focusLengths
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ForEach(lengths, id: \.self) { m in
                    Button(Focus.label(m)) { minutes = m }
                        .buttonStyle(.bordered).tint(minutes == m ? .accentColor : nil)
                        .contextMenu {
                            Button("Remove \(Focus.label(m))", role: .destructive) {
                                store.settings.focusLengths.removeAll { $0 == m }
                            }
                        }
                }
                Divider().frame(height: 18)
                TextField("Minutes", text: $text)
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 54)
                    .focused($typing)
                    .help("Any length, in minutes")
                    .onChange(of: text) { _, t in if let v = Int(t.filter(\.isNumber)), v > 0 { minutes = Focus.clamp(v) } }
                    .onChange(of: typing) { _, on in if !on { text = String(minutes) } }
                    .onSubmit { text = String(minutes) }
                Stepper("min", value: $minutes, in: 1...Focus.maxMinutes, step: 5).fixedSize()
                if !lengths.contains(minutes) {
                    Button { store.settings.focusLengths = Focus.normalized(lengths + [minutes]) } label: {
                        Label("Save \(Focus.label(minutes))", systemImage: "plus")
                    }
                    .controlSize(.small)
                    .disabled(lengths.count >= 8)
                    .help(lengths.count >= 8 ? "You can keep up to 8 lengths. Right-click one to remove it." : "Add \(Focus.label(minutes)) to the length buttons")
                }
            }
            Text("Type any length up to \(Focus.maxMinutes / 60) hours. Save it to keep it as a button; right-click a button to remove it.")
                .font(.app(.caption)).foregroundStyle(.secondary)
        }
        .onAppear { text = String(minutes) }
        .onChange(of: minutes) { _, m in if Int(text) != m { text = String(m) } }
    }
}

/// A task you can start working on (Focus › Work): one click and it's on.
struct WorkPickRow: View {
    let occ: Occurrence
    let start: () -> Void
    @State private var hovering = false
    var body: some View {
        let t = occ.task
        Button(action: start) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(t.color.color).frame(width: 3, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.title).lineLimit(1)
                    HStack(spacing: 8) {
                        if let p = t.priorityLevel { Label(p.title, systemImage: p.symbol).foregroundStyle(p.color) }
                        if let h = t.hardnessLevel { HardnessMeter(level: h, height: 9) }
                        if let m = t.typicalMinutes { Label("usually \(TaskStats.format(m))", systemImage: "stopwatch") }
                        if occ.isOverdue { Text("Overdue").foregroundStyle(.red) }
                        if let s = occ.start { Label(timeString(s), systemImage: "clock") }
                    }
                    .font(.app(.caption)).foregroundStyle(.secondary).labelStyle(CompactLabelStyle())
                }
                Spacer()
                Label("Work on this", systemImage: "play.fill").font(.app(.callout).weight(.medium))
                    .foregroundStyle(hovering ? Color.accentColor : .secondary)
            }
            .padding(.vertical, 7).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: Theme.radius).fill(hovering ? Color.accentColor.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Start working on “\(t.title)” now")
    }
}
