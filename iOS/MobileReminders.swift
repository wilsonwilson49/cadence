import SwiftUI

/// More › Reminders: notifications you program yourself, for anything. Same records as the Mac and web.
struct RemindersScreen: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        List {
            if store.customReminders.isEmpty {
                Text("Get notified about anything: drink water, stretch, take medicine. Tap + to make one.").foregroundStyle(.secondary)
            }
            ForEach(store.customReminders) { r in
                NavigationLink { MobileReminderEditor(id: r.id) } label: {
                    HStack {
                        Image(systemName: r.enabled ? "bell.fill" : "bell.slash").foregroundStyle(r.enabled ? .teal : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title.isEmpty ? "Untitled" : r.title)
                            Text(r.summary).font(.verdana(.caption)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
            .onDelete { idx in idx.map { store.customReminders[$0].id }.forEach(store.deleteCustomReminder) }
        }
        .navigationTitle("Reminders")
        .toolbar {
            Menu {
                Button("Blank") { add(CustomReminder(title: "New reminder")) }
                Section("Templates") { ForEach(CustomRemindersTemplates.all, id: \.title) { t in Button(t.title) { add(t) } } }
            } label: { Image(systemName: "plus") }
        }
    }

    private func add(_ r: CustomReminder) { var r = r; r.id = UUID(); r.createdAt = Date(); store.upsert(r) }
}

enum CustomRemindersTemplates {
    static var all: [CustomReminder] {
        var water = CustomReminder(title: "Drink water"); water.kind = .every; water.everyMinutes = 60
        var stretch = CustomReminder(title: "Stand up and stretch"); stretch.times = [660, 900]; stretch.weekdays = [2, 3, 4, 5, 6]
        var meds = CustomReminder(title: "Take medicine"); meds.times = [480, 1200]
        var eyes = CustomReminder(title: "Rest your eyes"); eyes.kind = .every; eyes.everyMinutes = 20; eyes.body = "Look at something 20 feet away for 20 seconds."
        var bed = CustomReminder(title: "Wind down for bed"); bed.times = [1350]
        return [water, stretch, meds, eyes, bed]
    }
}

private struct MobileReminderEditor: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var r = CustomReminder()
    @State private var loaded = false
    @State private var newTime = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $r.title)
                TextField("Message (optional)", text: $r.body, axis: .vertical)
                Toggle("On", isOn: $r.enabled)
            }
            Section {
                Picker("Repeat", selection: $r.kind) { ForEach(CustomReminder.Kind.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented)
                switch r.kind {
                case .times:
                    ForEach(r.times.sorted(), id: \.self) { m in
                        Text(timeString(minutes: m)).swipeActions { if r.times.count > 1 { Button("Remove", role: .destructive) { r.times.removeAll { $0 == m } } } }
                    }
                    HStack {
                        DatePicker("Add time", selection: $newTime, displayedComponents: .hourAndMinute)
                        Button("Add") { let m = minutes(newTime); if !r.times.contains(m) { r.times.append(m) } }
                    }
                    weekdays
                case .every:
                    Stepper("Every \(r.everyMinutes) min", value: $r.everyMinutes, in: 5...720, step: 5)
                    DatePicker("From", selection: minutesBinding(\.fromMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: minutesBinding(\.toMinutes), displayedComponents: .hourAndMinute)
                    weekdays
                case .once:
                    DatePicker("At", selection: $r.at)
                }
            } header: { Text("When") } footer: { Text(r.summary) }
            Section("Alert with") {
                Toggle("Sound", isOn: Binding(get: { r.channels.contains(.sound) || r.channels.contains(.notification) },
                                              set: { if $0 { r.channels.insert(.sound) } else { r.channels.remove(.sound); r.channels.remove(.notification) } }))
            }
            Section { Button("Delete Reminder", role: .destructive) { store.deleteCustomReminder(id); dismiss() } }
        }
        .navigationTitle(r.title.isEmpty ? "Reminder" : r.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if !loaded, let x = store.customReminders.first(where: { $0.id == id }) { r = x; loaded = true } }
        .onChange(of: r) { _, v in if loaded, store.customReminders.contains(where: { $0.id == id }) { store.upsert(v) } }
    }

    private var weekdays: some View {
        HStack(spacing: 4) {
            ForEach(1...7, id: \.self) { d in
                let on = r.weekdays.isEmpty || r.weekdays.contains(d)
                Button(Calendar.current.veryShortWeekdaySymbols[d - 1]) {
                    var w = Set(r.weekdays.isEmpty ? Array(1...7) : r.weekdays)
                    if on { w.remove(d) } else { w.insert(d) }
                    if !w.isEmpty { r.weekdays = w.count == 7 ? [] : w.sorted() }
                }
                .buttonStyle(.bordered).tint(on ? .teal : .secondary).frame(maxWidth: .infinity)
            }
        }
    }

    private func minutes(_ d: Date) -> Int { let c = Calendar.current.dateComponents([.hour, .minute], from: d); return (c.hour ?? 0) * 60 + (c.minute ?? 0) }
    private func minutesBinding(_ kp: WritableKeyPath<CustomReminder, Int>) -> Binding<Date> {
        Binding(get: { dayAt(Date(), minutes: r[keyPath: kp]) }, set: { r[keyPath: kp] = minutes($0) })
    }
}
