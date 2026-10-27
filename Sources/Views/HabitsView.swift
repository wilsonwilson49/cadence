import SwiftUI

/// The habit tracker (Atomic Habits): streaks, a 30-day grid, never missing twice, identity votes, and the
/// habit scorecard. Habits are repeating items; their check-offs still ask for a reflection like everything else.
struct HabitsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var google: GoogleCalendar
    @State private var newScore = ""

    private var habits: [PlanTask] {
        store.tasks.filter { $0.isHabit && $0.archived != true && google.isShown($0) }.sorted { $0.title < $1.title }
    }

    var body: some View {
        let list = habits
        let stats = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.habitStats()) })
        let due = list.filter { stats[$0.id]?.today != nil }
        let doneToday = due.filter { stats[$0.id]?.today == .done }.count
        let votes = stats.values.reduce(0) { $0 + $1.votes }
        var identities: [(String, Int)] = []
        for t in list { if let id = t.habit?.identity, !id.isEmpty {
            if let i = identities.firstIndex(where: { $0.0 == id }) { identities[i].1 += stats[t.id]?.votes ?? 0 } else { identities.append((id, stats[t.id]?.votes ?? 0)) }
        } }
        return VStack(spacing: 0) {
            ScreenHeader(title: "Habits", subtitle: "Small habits, repeated. Every check-off is a vote for the person you're becoming.") {
                Button { model.newHabit() } label: { Label("New Habit", systemImage: "plus") }.buttonStyle(.borderedProminent)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !list.isEmpty { HabitTable(habits: list, stats: stats) }
                    HStack(spacing: 12) {
                        stat("\(doneToday)/\(due.count)", "done today", "checkmark", .green)
                        stat("\(stats.values.map(\.streak).max() ?? 0)", "best current streak", "flame", .orange)
                        stat("\(votes)", "votes cast", "arrow.triangle.2.circlepath", .indigo)
                        stat("\(list.count)", list.count == 1 ? "habit" : "habits", "repeat", .teal)
                    }
                    if !identities.isEmpty {
                        FlowRow(identities.map { id, n in
                            AnyView(Label { Text("I am someone who \(id)  ") + Text("\(n) vote\(n == 1 ? "" : "s")").bold().foregroundColor(.accentColor) }
                                icon: { Image(systemName: "quote.opening") }
                                .font(.callout).padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Capsule().fill(Color.accentColor.opacity(0.1))))
                        })
                    }
                    if list.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle").font(.system(size: 36)).foregroundStyle(.secondary)
                            Text("No habits yet").font(.title3.weight(.semibold))
                            Text("Start tiny: pick one thing you want to do every day, and the 2-minute version of it.").foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14)], spacing: 14) {
                            ForEach(list) { t in HabitCard(task: t, stats: stats[t.id] ?? t.habitStats()) }
                        }
                    }
                    scorecard
                    laws
                }
                .padding(22)
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ symbol: String, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.title3.bold()).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.08)))
    }

    private var scorecard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle(text: "Habit scorecard", symbol: "list.bullet.clipboard")
                Text("what you already do, rated").font(.caption).foregroundStyle(.secondary)
            }
            Card {
                VStack(spacing: 0) {
                    ForEach($store.settings.habitScorecard) { $item in
                        HStack(spacing: 10) {
                            Text(item.text).frame(maxWidth: .infinity, alignment: .leading)
                            Picker("", selection: $item.rating) {
                                Text("+").tag("+"); Text("=").tag("="); Text("–").tag("-")
                            }
                            .pickerStyle(.segmented).labelsHidden().frame(width: 110)
                            if item.rating == "-" {
                                Button { model.newHabit(style: "replace", replaces: item.text.prefix(1).lowercased() + item.text.dropFirst()) } label: {
                                    Label("Replace it", systemImage: "arrow.triangle.2.circlepath")
                                }
                                .controlSize(.small)
                            }
                            Button { store.settings.habitScorecard.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).help("Remove")
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                    HStack {
                        TextField("Something you do every day, e.g. check my phone right after waking up", text: $newScore)
                            .textFieldStyle(.plain).onSubmit(addScore)
                        Button("Add", action: addScore).disabled(newScore.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.vertical, 6)
                }
            }
            Text("Rate each one good (+), neutral (=) or bad (–) for who you want to be. “Replace it” starts a habit that takes a bad one's place.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func addScore() {
        let t = newScore.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        store.settings.habitScorecard.append(ScoreItem(text: t))
        newScore = ""
    }

    private var laws: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
            ForEach(Array([
                ("Make it obvious", "Give it a cue: a time and place, or stack it after a habit you already have."),
                ("Make it attractive", "Pair it with something you enjoy, and spend time with people who already do it."),
                ("Make it easy", "Shrink it to a 2-minute version. Showing up matters more than doing it well."),
                ("Make it satisfying", "Reward yourself right after, and don't break the chain: never miss twice."),
            ].enumerated()), id: \.offset) { i, law in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)").font(.callout.bold()).foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24).background(Circle().fill(Color.accentColor.opacity(0.12)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(law.0).font(.callout.weight(.semibold))
                        Text(law.1).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
    }
}

/// The tracker grid: a row per habit, a column per day (newest on the right). Clicking today's cell, or a day
/// that was missed, checks the habit off with the usual reflection.
private struct HabitTable: View {
    @EnvironmentObject private var model: AppModel
    let habits: [PlanTask]
    let stats: [UUID: PlanTask.HabitStats]
    @AppStorage("habitTrackerDays") private var range = 14
    private let rowH: CGFloat = 26, cellW: CGFloat = 24

    var body: some View {
        let first = stats[habits[0].id]?.grid.suffix(range) ?? []
        let days = first.map(\.day)
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(text: "Tracker", symbol: "calendar")
                    Spacer()
                    Picker("", selection: $range) { Text("Week").tag(7); Text("2 weeks").tag(14); Text("Month").tag(30) }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
                HStack(alignment: .top, spacing: 8) {
                    // Habit names stay put while the days scroll.
                    VStack(alignment: .leading, spacing: 3) {
                        Color.clear.frame(width: 170, height: 30)
                        ForEach(habits) { t in
                            HStack(spacing: 7) {
                                Circle().fill(t.color.color).frame(width: 8, height: 8)
                                Text(t.title).lineLimit(1)
                            }
                            .frame(width: 170, height: rowH, alignment: .leading)
                        }
                        Text("Done").font(.caption).foregroundStyle(.secondary).frame(height: 18)
                    }
                    ScrollView(.horizontal, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 3) {
                                ForEach(days, id: \.self) { d in
                                    VStack(spacing: 1) {
                                        Text(Calendar.current.veryShortWeekdaySymbols[Calendar.current.component(.weekday, from: d) - 1])
                                            .font(.system(size: 10)).foregroundStyle(.secondary)
                                        Text(d.formatted(.dateTime.day())).font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(d.isToday ? Color.white : .primary)
                                            .frame(width: 20, height: 16)
                                            .background(Capsule().fill(d.isToday ? Color.accentColor : .clear))
                                    }
                                    .frame(width: cellW, height: 30)
                                }
                            }
                            ForEach(habits) { t in
                                HStack(spacing: 3) {
                                    ForEach(Array((stats[t.id]?.grid.suffix(range) ?? []).enumerated()), id: \.offset) { _, c in cell(t, c.day, c.state) }
                                }
                                .frame(height: rowH)
                            }
                            HStack(spacing: 3) {
                                ForEach(Array(days.enumerated()), id: \.offset) { i, _ in
                                    let states = habits.compactMap { Array(stats[$0.id]?.grid.suffix(range) ?? [])[safe: i]?.state }
                                    let sched = states.filter { $0 != .off }.count, done = states.filter { $0 == .done }.count
                                    Text(sched > 0 ? "\(done)/\(sched)" : "").font(.system(size: 9.5).monospacedDigit())
                                        .foregroundStyle(sched > 0 && done == sched ? Color.green : .secondary)
                                        .frame(width: cellW, height: 18)
                                }
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    .defaultScrollAnchor(.trailing)
                    // As wide as the days need (so they sit next to the names), scrolling only when the window is narrower.
                    .frame(maxWidth: CGFloat(days.count) * (cellW + 3))
                    VStack(spacing: 3) {
                        HStack(spacing: 0) {
                            Image(systemName: "flame").font(.caption).foregroundStyle(.secondary).frame(width: 34)
                            Text("%").font(.caption).foregroundStyle(.secondary).frame(width: 40)
                        }
                        .frame(height: 30)
                        ForEach(habits) { t in
                            HStack(spacing: 0) {
                                Text("\(stats[t.id]?.streak ?? 0)").font(.callout.bold()).foregroundStyle(.orange).frame(width: 34)
                                Text(stats[t.id]?.rate.map { "\($0)%" } ?? "–").font(.caption).foregroundStyle(.secondary).frame(width: 40)
                            }
                            .frame(height: rowH)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder private func cell(_ t: PlanTask, _ day: Date, _ state: PlanTask.DayState) -> some View {
        let c = t.color.color
        let canCheck = state == .open || state == .lapsed
        RoundedRectangle(cornerRadius: 6)
            .fill(state == .done ? c : state == .missed ? Color.red.opacity(0.75) : state == .off ? Color.primary.opacity(0.04) : state == .open || state == .lapsed ? Color.clear : Color.primary.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(state == .open ? c : state == .lapsed ? Color.red.opacity(0.45) : .clear, lineWidth: state == .open ? 2 : 1.5))
            .overlay {
                if state == .done { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) }
                if state == .missed { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
            }
            .frame(width: cellW, height: 24)
            .contentShape(Rectangle())
            .onTapGesture { if canCheck { model.beginReflection(Occurrence(task: t, day: day)) } }
            .help("\(t.title) · \(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())): \(["done": "done", "missed": "didn't do it", "lapsed": "missed", "open": "to do today", "off": "not scheduled"][state.rawValue] ?? "")\(canCheck ? " (click to check off)" : "")")
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

private struct HabitCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    let task: PlanTask
    let stats: PlanTask.HabitStats

    var body: some View {
        let h = task.habit ?? HabitInfo()
        let today = Date().startOfDay
        let occ = task.occurs(on: today) ? Occurrence(task: task, day: today) : nil
        let color = task.color.color
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(.headline).lineLimit(1)
                    Text("\(task.planSummary ?? "Every day") · \(h.styleLabel)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(spacing: 0) {
                    Image(systemName: "flame.fill").foregroundStyle(.orange).font(.caption)
                    Text("\(stats.streak)").font(.title3.bold()).monospacedDigit()
                    Text("best \(stats.best)").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .help("Current streak (best \(stats.best))")
            }
            .fixedSize(horizontal: false, vertical: true)
            if let s = task.habitSentence { Text(s).font(.callout).italic().foregroundStyle(.secondary) }
            if h.style == "break", let app = h.app, !app.isEmpty, let used = appSecondsToday(app) {
                let limit = (h.limitMinutes ?? 0) * 60
                Label("\(app) today: \(durationString(seconds: used))\(limit > 0 ? " of \(durationString(seconds: limit))" : "")", systemImage: "desktopcomputer")
                    .font(.caption).foregroundStyle(limit > 0 && used > limit ? Color.red : .secondary)
            }
            HStack(spacing: 3) {
                ForEach(stats.grid, id: \.day) { g in
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(fill(g.state, color))
                        .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(stroke(g.state, color), lineWidth: 1.5))
                        .aspectRatio(1, contentMode: .fit)
                        .help("\(g.day.formatted(.dateTime.month(.abbreviated).day())): \(label(g.state))")
                }
            }
            HStack(spacing: 12) {
                Text(stats.rate.map { "\($0)% kept" } ?? "New")
                Text("\(stats.votes) vote\(stats.votes == 1 ? "" : "s")\(h.identity?.isEmpty == false ? " for who you're becoming" : "")")
                if let two = h.twoMinute, !two.isEmpty { Label(two, systemImage: "timer") }
                if let r = h.reward, !r.isEmpty { Label("then \(r)", systemImage: "gift") }
            }
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if stats.missTwice {
                Label("Missed last time. Never miss twice: even the 2-minute version counts today.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }
            HStack {
                if let occ, !occ.isResolved {
                    Button { model.beginReflection(occ) } label: { Label("Done today…", systemImage: "checkmark") }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button { model.beginReflection(occ, missed: true) } label: { Label("Didn't do it…", systemImage: "xmark") }
                        .controlSize(.small)
                } else if occ?.isDone == true {
                    Label("Done today", systemImage: "checkmark").font(.caption).foregroundStyle(.green)
                } else if occ?.isMissed == true {
                    Label("Not done today", systemImage: "xmark").font(.caption).foregroundStyle(.red)
                } else if let next = task.nextOccurrence(onOrAfter: today.adding(days: 1)) {
                    Text("Next: \(next.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Edit") { model.edit(task) }.buttonStyle(.borderless).controlSize(.small)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)))
    }

    private func appSecondsToday(_ app: String) -> Int? {
        let days = store.screenDays(on: Date())
        guard !days.isEmpty else { return nil }
        let want = app.lowercased()
        return days.flatMap(\.apps).filter { $0.name.lowercased().contains(want) }.reduce(0) { $0 + $1.seconds }
    }

    private func fill(_ s: PlanTask.DayState, _ c: Color) -> Color {
        switch s {
        case .done: return c
        case .missed: return .red.opacity(0.7)
        case .lapsed, .open: return .clear
        case .off: return Color.primary.opacity(0.05)
        }
    }
    private func stroke(_ s: PlanTask.DayState, _ c: Color) -> Color {
        switch s {
        case .lapsed: return .red.opacity(0.45)
        case .open: return c
        default: return .clear
        }
    }
    private func label(_ s: PlanTask.DayState) -> String {
        ["done": "done", "missed": "didn't do it", "lapsed": "missed", "open": "today", "off": "not scheduled"][s.rawValue] ?? ""
    }
}

/// Wraps items onto as many rows as needed.
struct FlowRow: View {
    let items: [AnyView]
    init(_ items: [AnyView]) { self.items = items }
    var body: some View {
        FlowLayout(spacing: 8) { ForEach(items.indices, id: \.self) { items[$0] } }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}
