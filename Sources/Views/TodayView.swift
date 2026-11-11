import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var google: GoogleCalendar
    @EnvironmentObject private var engine: ReminderEngine
    @State private var quickAdd = ""

    var body: some View {
        let today = Date().startOfDay
        let items = store.checklist(on: today)
        let overdue = store.overdue()
        // Until-done items that aren't due yet sit under "Due later" and stay out of the ring (unless urgent).
        let counted = store.countedToday(overdue + items)
        let later = store.dueLater(overdue + items)
        let all = counted
        // Project subtasks on today's list count in the ring too (see the "On today" setting).
        let proj = store.projectToday()
        let projDone = proj.filter { $0.item?.isDone == true }.count
        let done = all.filter(\.isDone).count + projDone
        let settled = all.filter(\.isResolved).count + projDone
        let total = all.count + proj.count
        let events = schedule(on: today, store: store, google: google)

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(greeting).font(.title3).foregroundStyle(.secondary)
                        Text(today.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.largeTitle.bold())
                        Text(statusLine(done: done, settled: settled, total: total))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProgressRing(done: done, total: total, size: 76, lineWidth: 9, showsLeft: store.settings.ringShowsLeft)
                        .contentShape(Circle())
                        .onTapGesture { store.settings.ringShowsLeft.toggle() }
                        .contextMenu { RingModePicker() }
                }

                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor).font(.title3)
                    TextField("Quick add to today — press Return", text: $quickAdd)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .onSubmit(addQuick)
                    if !quickAdd.isEmpty {
                        Button("Add", action: addQuick).controlSize(.small)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))

                if !overdue.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(text: "Overdue", symbol: "exclamationmark.circle", count: overdue.count)
                        Card { VStack(spacing: 0) { rows(overdue) } }
                    }
                }

                // Tasks that stay on until you do them get their own section, apart from what's on for today.
                let shown = counted.filter { o in !overdue.contains { $0.id == o.id } }
                let habits = shown.filter { $0.isHabit && !$0.isUntilDone }
                let daily = shown.filter { !$0.isHabit && !$0.isUntilDone }
                let ongoing = shown.filter(\.isUntilDone)
                VStack(alignment: .leading, spacing: 6) {
                    SectionTitle(text: "Today's checklist", symbol: "checklist", count: daily.count)
                    Card {
                        if daily.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "sun.max").font(.title2).foregroundStyle(.orange)
                                VStack(alignment: .leading) {
                                    Text(ongoing.isEmpty ? "Nothing scheduled for today." : "Nothing else scheduled for today.")
                                    Text("Add a task above, or press ⌘N for one with a time and repeat schedule.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                        } else {
                            VStack(spacing: 0) { rows(daily) }
                        }
                    }
                }
                if !habits.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            SectionTitle(text: "Habits", symbol: "arrow.triangle.2.circlepath", count: habits.filter { !$0.isResolved }.count)
                            Spacer()
                            Button("Habit tracker") { model.screen = .habits }.controlSize(.small)
                        }
                        Card { VStack(spacing: 0) { rows(habits) } }
                    }
                }
                if !ongoing.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            SectionTitle(text: "Until done", symbol: "flame", count: ongoing.count)
                            Text("stays on your list until you check it off or mark it “didn't do it”").font(.caption).foregroundStyle(.secondary)
                        }
                        Card { VStack(spacing: 0) { rows(ongoing) } }
                    }
                }
                if !later.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            SectionTitle(text: "Due later", symbol: "calendar.badge.clock", count: later.count)
                            Text("not counted in today's progress · mark one urgent to work on it today").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            ProjectTodayMenu()
                        }
                        Card { VStack(spacing: 0) {
                            ForEach(Array(later.enumerated()), id: \.element.id) { i, occ in
                                if i > 0 { Divider().padding(.leading, 42) }
                                HStack {
                                    ChecklistRow(occ: occ)
                                    if let d = occ.deadline {
                                        Text("due \(d.formatted(.dateTime.weekday(.abbreviated))) \(timeString(d))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    Button { store.setUrgent(occ.task.id, true) } label: { Label("Urgent", systemImage: "exclamationmark.circle") }
                                        .controlSize(.small).help("Put it on today's list and in today's progress")
                                }
                            }
                        } }
                    }
                }
                let upcoming = store.upcomingOneOffs()
                if !upcoming.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            SectionTitle(text: "Upcoming", symbol: "calendar.badge.clock", count: upcoming.count)
                            Text("one-off tasks in the next 30 days · not counted today").font(.caption).foregroundStyle(.secondary)
                        }
                        Card { VStack(spacing: 0) {
                            ForEach(Array(upcoming.enumerated()), id: \.element.id) { i, occ in
                                if i > 0 { Divider().padding(.leading, 42) }
                                HStack {
                                    ChecklistRow(occ: occ, showDate: true)
                                    Text(dueRelative(DateKey.string(occ.day))).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } }
                    }
                }
                ProjectTodaySection()
                ProjectUpcomingSection()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Checking an item off asks for a reflection of at least \(store.settings.minReflectionWords) words. They're saved under Reflections.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        SectionTitle(text: "Schedule", symbol: "calendar", count: events.count)
                        Button { model.newEvent() } label: { Label("New event", systemImage: "plus") }.controlSize(.small)
                    }
                    Card {
                        if events.isEmpty {
                            Text("No events today. Events show on your calendars but never on the checklist.").foregroundStyle(.secondary)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(events.enumerated()), id: \.element.id) { i, ev in
                                    if i > 0 { Divider().padding(.leading, 76) }
                                    EventRow(ev: ev)
                                }
                            }
                        }
                    }
                }

                remindersCard
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private func rows(_ list: [Occurrence]) -> some View {
        ForEach(Array(list.enumerated()), id: \.element.id) { i, occ in
            if i > 0 { Divider().padding(.leading, 42) }
            ChecklistRow(occ: occ)
        }
    }

    private var remindersCard: some View {
        let s = store.settings
        return HStack(spacing: 14) {
            Image(systemName: "bell.and.waves.left.and.right").font(.title2).foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.nudgeEnabled
                     ? "Checklist reminder every \(s.nudgeIntervalMinutes) min while you're at your Mac"
                     : "Recurring checklist reminders are off")
                    .font(.callout.weight(.medium))
                Text(s.nudgeEnabled
                     ? "Next one around \(timeString(engine.nextNudge)). You'll also get a check-in whenever the Mac wakes or unlocks."
                     : "Turn them on in Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Check in now") { engine.triggerCheckIn(reason: .manual) }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.indigo.opacity(0.08)))
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private func statusLine(done: Int, settled: Int, total: Int) -> String {
        if total == 0 { return "A clear day." }
        if done == total { return "Everything is checked off. Nice work." }
        if settled == total { return "All settled: \(done) done, \(total - done) not done." }
        return "\(total - settled) of \(total) left to check off."
    }

    private func addQuick() {
        let title = quickAdd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        store.upsert(PlanTask(title: title, startDate: Date().startOfDay, channels: store.settings.defaultChannels))
        quickAdd = ""
    }
}
