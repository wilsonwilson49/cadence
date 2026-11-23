import SwiftUI

/// Reminders you program yourself, for anything — not just tasks.
struct CustomRemindersView: View {
    @EnvironmentObject private var store: Store
    @State private var selected: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Reminders", subtitle: "Get notified about anything: drink water, stretch, take medicine. Syncs to your iPhone and the web.") {
                Menu {
                    Button("Blank") { add(CustomReminder(title: "New reminder")) }
                    Divider()
                    ForEach(Self.templates, id: \.title) { t in Button(t.title) { add(t) } }
                } label: { Label("New Reminder", systemImage: "plus") }
                .fixedSize()
            }
            HStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(store.customReminders) { r in
                        HStack {
                            Image(systemName: r.enabled ? "bell.fill" : "bell.slash").foregroundStyle(r.enabled ? .teal : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title.isEmpty ? "Untitled" : r.title).font(.app(.callout).weight(.medium)).lineLimit(1)
                                Text(r.summary).font(.app(.caption)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .tag(r.id)
                        .contextMenu {
                            Button(r.enabled ? "Turn off" : "Turn on") { var m = r; m.enabled.toggle(); store.upsert(m) }
                            Button("Delete", role: .destructive) { store.deleteCustomReminder(r.id); if selected == r.id { selected = nil } }
                        }
                    }
                }
                .frame(width: 280)
                Divider()
                if let id = selected, let r = store.customReminders.first(where: { $0.id == id }) {
                    ReminderEditor(reminder: r) { store.upsert($0) } onDelete: { store.deleteCustomReminder(id); selected = nil }
                        .id(id)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "bell.badge").font(.app(.largeTitle)).foregroundStyle(.secondary)
                        Text(store.customReminders.isEmpty ? "No reminders yet. Make one with New Reminder." : "Pick a reminder to edit it.")
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func add(_ r: CustomReminder) {
        var r = r; r.id = UUID(); r.createdAt = Date()
        store.upsert(r); selected = r.id
    }

    static var templates: [CustomReminder] {
        var water = CustomReminder(title: "Drink water"); water.kind = .every; water.everyMinutes = 60
        var stretch = CustomReminder(title: "Stand up and stretch"); stretch.kind = .times; stretch.times = [11 * 60, 15 * 60]; stretch.weekdays = [2, 3, 4, 5, 6]
        var meds = CustomReminder(title: "Take medicine"); meds.times = [8 * 60, 20 * 60]
        var eyes = CustomReminder(title: "Rest your eyes"); eyes.kind = .every; eyes.everyMinutes = 20; eyes.body = "Look at something 20 feet away for 20 seconds."
        var bed = CustomReminder(title: "Wind down for bed"); bed.times = [22 * 60 + 30]
        return [water, stretch, meds, eyes, bed]
    }
}

private struct ReminderEditor: View {
    @State var reminder: CustomReminder
    let save: (CustomReminder) -> Void
    let onDelete: () -> Void
    @State private var newTime = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $reminder.title)
                TextField("Message (optional)", text: $reminder.body, axis: .vertical).lineLimit(1...4)
                Toggle("On", isOn: $reminder.enabled)
            }
            Section("When") {
                Picker("Repeat", selection: $reminder.kind) { ForEach(CustomReminder.Kind.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented)
                switch reminder.kind {
                case .times:
                    ForEach(reminder.times.sorted(), id: \.self) { m in
                        HStack {
                            Text(timeString(minutes: m))
                            Spacer()
                            Button { reminder.times.removeAll { $0 == m } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).disabled(reminder.times.count <= 1)
                        }
                    }
                    HStack {
                        DatePicker("Add time", selection: $newTime, displayedComponents: .hourAndMinute)
                        Button("Add") {
                            let c = Calendar.current.dateComponents([.hour, .minute], from: newTime)
                            let m = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                            if !reminder.times.contains(m) { reminder.times.append(m) }
                        }
                    }
                    weekdays
                case .every:
                    LabeledContent("Every") { MinutesField(value: $reminder.everyMinutes, range: 5...720, choices: [10, 15, 20, 30, 45, 60, 90, 120, 180]) }
                    DatePicker("From", selection: minutesBinding(\.fromMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: minutesBinding(\.toMinutes), displayedComponents: .hourAndMinute)
                    weekdays
                case .once:
                    DatePicker("At", selection: $reminder.at)
                }
                Text(reminder.summary).font(.app(.caption)).foregroundStyle(.secondary)
            }
            Section("Alert with") {
                ForEach([AlertChannel.notification, .banner, .sound], id: \.self) { ch in
                    Toggle(ch.label, isOn: Binding(get: { reminder.channels.contains(ch) },
                                                   set: { if $0 { reminder.channels.insert(ch) } else { reminder.channels.remove(ch) } }))
                }
            }
            Section { Button("Delete Reminder", role: .destructive, action: onDelete) }
        }
        .formStyle(.grouped)
        .onChange(of: reminder) { _, r in save(r) }
    }

    private var weekdays: some View {
        HStack(spacing: 4) {
            Text("Days").padding(.trailing, 6)
            ForEach(1...7, id: \.self) { d in
                let on = reminder.weekdays.isEmpty || reminder.weekdays.contains(d)
                Button(Calendar.current.veryShortWeekdaySymbols[d - 1]) {
                    var w = Set(reminder.weekdays.isEmpty ? Array(1...7) : reminder.weekdays)
                    if on { w.remove(d) } else { w.insert(d) }
                    if w.isEmpty { return }
                    reminder.weekdays = w.count == 7 ? [] : w.sorted()
                }
                .buttonStyle(.bordered).tint(on ? .teal : .secondary)
            }
        }
    }

    private func minutesBinding(_ kp: WritableKeyPath<CustomReminder, Int>) -> Binding<Date> {
        Binding(get: { dayAt(Date(), minutes: reminder[keyPath: kp]) },
                set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); reminder[keyPath: kp] = (c.hour ?? 0) * 60 + (c.minute ?? 0) })
    }
}
