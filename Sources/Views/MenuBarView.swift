import SwiftUI

/// The menu bar dropdown: a brief, compact version of today's checklist.
///
/// Every row has a fixed height and the list gets an explicit height. The dropdown sizes itself
/// to its content, and a ScrollView with only a max height asks for almost nothing there, so the list
/// used to collapse to zero and the dropdown looked empty.
struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var engine: ReminderEngine
    @State private var showSettled = false
    /// Grouped: To do, Habits, Until done, Project tasks and Due later each get a heading. Not grouped: one list by time.
    @AppStorage("menuBarGrouped") private var grouped = true

    private static let rowHeight: CGFloat = 26
    private static let headerHeight: CGFloat = 20
    private static let maxHeight: CGFloat = 26 * 17

    /// One line of the list: a heading, a checklist item, or a project subtask. `later` = due later (not counted).
    private enum Entry: Identifiable {
        case header(String, Int, String?)
        case occ(Occurrence, later: Bool)
        case proj(ProjectDeadline, later: Bool)
        var id: String {
            switch self {
            case .header(let t, _, _): return "h|" + t
            case .occ(let o, let l): return (l ? "l|" : "o|") + o.id
            case .proj(let d, let l): return (l ? "pl|" : "p|") + d.id
            }
        }
        var height: CGFloat { if case .header = self { return MenuBarView.headerHeight } else { return MenuBarView.rowHeight } }
    }

    var body: some View {
        let items = store.countedToday()
        let later = store.dueLater().filter { !$0.isResolved }
        let projLater = store.projectUpcoming()
        let open = items.filter { !$0.isResolved }
        let settled = items.filter(\.isResolved)
        // Project subtasks on today's list count too.
        let proj = store.projectToday()
        let projOpen = proj.filter { $0.item?.isDone == false }, projDone = proj.filter { $0.item?.isDone == true }
        let done = settled.filter(\.isDone).count + projDone.count
        let openCount = open.count + projOpen.count, total = items.count + proj.count
        let laterCount = later.count + projLater.count
        let entries = grouped ? groupedEntries(open, projOpen, later, projLater) : flatEntries(open, projOpen, later, projLater)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today · \(Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))").font(.headline)
                    Text((total == 0 ? "Nothing scheduled" : openCount == 0 ? "All settled" : "\(openCount) left · \(done) done") + (laterCount > 0 ? " · \(laterCount) later" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { grouped.toggle() } label: {
                    Image(systemName: grouped ? "list.bullet.indent" : "list.bullet")
                }
                .buttonStyle(.borderless)
                .help(grouped ? "Grouped by kind · click for one list in time order" : "One list in time order · click to group by kind")
                ProgressRing(done: done, total: total, size: 26, lineWidth: 3.5, showsLeft: store.settings.ringShowsLeft)
            }
            Divider()
            if total == 0 && laterCount == 0 {
                Text("Nothing on today's checklist.").font(.callout).foregroundStyle(.secondary)
                    .frame(height: Self.rowHeight)
            } else {
                if openCount == 0 && total > 0 {
                    Label("Everything's checked off.", systemImage: "checkmark.seal").font(.callout).foregroundStyle(.green)
                        .frame(height: Self.rowHeight)
                }
                list(entries)
                if !settled.isEmpty || !projDone.isEmpty {
                    Button { showSettled.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showSettled ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            Text("\(settled.count + projDone.count) settled")
                        }
                        .font(.caption).foregroundStyle(.secondary).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showSettled { list(settled.map { .occ($0, later: false) } + projDone.map { .proj($0, later: false) }) }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Button { model.newTask() } label: { Image(systemName: "plus") }.help("New task")
                Button { engine.triggerCheckIn(reason: .manual) } label: { Image(systemName: "sun.max") }.help("Check in")
                Button("Open Cadence") { model.openChecklist() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 310)
    }

    /// Headings by kind, with "Due later" (not counted) last.
    private func groupedEntries(_ open: [Occurrence], _ projOpen: [ProjectDeadline], _ later: [Occurrence], _ projLater: [ProjectDeadline]) -> [Entry] {
        var out: [Entry] = []
        func add(_ title: String, _ occs: [Occurrence], _ projs: [ProjectDeadline] = [], note: String? = nil, later: Bool = false) {
            guard !occs.isEmpty || !projs.isEmpty else { return }
            out.append(.header(title, occs.count + projs.count, note))
            out += occs.map { .occ($0, later: later) } + projs.map { .proj($0, later: later) }
        }
        add("To do", open.filter { !$0.isHabit && !$0.isUntilDone })
        add("Habits", open.filter { $0.isHabit && !$0.isUntilDone })
        add("Until done", open.filter(\.isUntilDone))
        add("Project tasks", [], projOpen)
        add("Due later", later, projLater, note: "not counted", later: true)
        return out
    }

    /// One list in time order: today's items first by time, then what's due later by deadline.
    private func flatEntries(_ open: [Occurrence], _ projOpen: [ProjectDeadline], _ later: [Occurrence], _ projLater: [ProjectDeadline]) -> [Entry] {
        let endOfDay = Date().startOfDay.adding(days: 1)
        func key(_ d: String?) -> Date { d.flatMap(DateKey.date)?.adding(days: 1) ?? endOfDay }
        var today: [(Date, Entry)] = open.map { ($0.start ?? $0.deadline ?? endOfDay, .occ($0, later: false)) }
        today += projOpen.map { (key($0.due), .proj($0, later: false)) }
        var rest: [(Date, Entry)] = later.map { ($0.deadline ?? .distantFuture, .occ($0, later: true)) }
        rest += projLater.map { (key($0.due), .proj($0, later: true)) }
        return today.sorted { $0.0 < $1.0 }.map(\.1) + rest.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// Fixed-height rows, scrolling only once it gets tall.
    @ViewBuilder private func list(_ entries: [Entry]) -> some View {
        let height = entries.reduce(0) { $0 + $1.height }
        let stack = VStack(spacing: 0) {
            ForEach(entries) { e in
                switch e {
                case .header(let t, let n, let note):
                    HStack(spacing: 5) {
                        Text(t.uppercased()).font(.system(size: 10, weight: .semibold))
                        Text("\(n)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                        if let note { Text("· \(note)").font(.system(size: 10)) }
                        Spacer()
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .frame(height: Self.headerHeight, alignment: .bottom)
                case .occ(let o, let l):
                    MenuRow(occ: o, later: l).frame(height: Self.rowHeight)
                case .proj(let d, let l):
                    MenuProjectRow(d: d, later: l).frame(height: Self.rowHeight)
                }
            }
        }
        if height > Self.maxHeight {
            ScrollView { stack }.frame(height: Self.maxHeight)
        } else {
            stack
        }
    }
}

/// A project subtask on today's list: check circle, colour, title, and its deadline (or "urgent").
private struct MenuProjectRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    let d: ProjectDeadline
    var later = false
    @State private var hovering = false

    var body: some View {
        let done = d.item?.isDone == true
        HStack(spacing: 7) {
            if d.item != nil {
                Button { store.toggleProjectItem(d) } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : hovering ? "checkmark.circle" : "circle")
                        .font(.system(size: 14)).foregroundStyle(done ? d.project.color.color : .secondary)
                }
                .buttonStyle(.plain).help(done ? "Undo" : "Mark done")
            } else {
                Image(systemName: "flag.checkered").font(.system(size: 12)).foregroundStyle(d.project.color.color).frame(width: 14)
            }
            RoundedRectangle(cornerRadius: 1.5).fill(d.project.color.color).frame(width: 3, height: 14)
            Text(d.item == nil ? "\(d.title.isEmpty ? "Untitled project" : d.title) (project)" : d.title.isEmpty ? "Untitled" : d.title)
                .lineLimit(1).truncationMode(.tail)
                .strikethrough(done).foregroundStyle(done ? .secondary : .primary).opacity(later ? 0.8 : 1)
            Spacer(minLength: 6)
            Group {
                if d.item?.isUrgent == true && !done { Text("Urgent").foregroundStyle(.red) }
                else if later, let due = d.due { Text("due \(shortDay(due))").foregroundStyle(.secondary) }
                else if let due = d.due { Text(due < DateKey.string(Date()) && !done ? "Overdue" : shortDay(due)).foregroundStyle(due < DateKey.string(Date()) && !done ? .red : .secondary) }
            }
            .font(.caption.monospacedDigit()).lineLimit(1).fixedSize()
        }
        .font(.callout)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("\(d.project.title)\(d.path.isEmpty ? "" : " › " + d.path.joined(separator: " › "))")
        .contextMenu {
            if later, let item = d.item {
                Button("Mark urgent (on today's list)") { store.editProject(d.project.id) { p in p.update(item.id) { $0.urgent = true } } }
            }
            Button("Open project") { model.openProjectID = d.project.id; model.openChecklist(); model.screen = .projects }
        }
    }
}

/// One line: check circle, colour, title, and when (time, "until 4:30 PM", overdue).
private struct MenuRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    let occ: Occurrence
    /// Due later: not counted today; shows when it's due, and an Urgent button on hover.
    var later = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Button { model.toggle(occ) } label: {
                Image(systemName: occ.isDone ? "checkmark.circle.fill" : occ.isMissed ? "xmark.circle.fill"
                      : hovering ? "checkmark.circle" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(occ.isDone ? occ.task.color.color : occ.isMissed ? Color.red : .secondary)
            }
            .buttonStyle(.plain)
            .help(occ.isResolved ? "Undo" : "Check off (you'll write a short reflection)")
            RoundedRectangle(cornerRadius: 1.5).fill(occ.task.color.color).frame(width: 3, height: 14)
            Text(occ.task.title)
                .lineLimit(1).truncationMode(.tail)
                .strikethrough(occ.isResolved)
                .foregroundStyle(occ.isResolved ? .secondary : .primary)
                .opacity(later ? 0.8 : 1)
            if occ.task.isUrgent && occ.isUntilDone && !occ.isResolved {
                Text("!").font(.caption.weight(.heavy)).foregroundStyle(.red).help("Urgent")
            }
            Spacer(minLength: 6)
            if later && hovering {
                Button("Urgent") { store.setUrgent(occ.task.id, true) }
                    .buttonStyle(.borderless).font(.caption.weight(.semibold)).foregroundStyle(.red)
                    .help("Put it on today's list and in today's progress")
            } else {
                when.font(.caption.monospacedDigit()).lineLimit(1).fixedSize()
            }
        }
        .font(.callout)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { OccurrenceMenu(occ: occ) }
    }

    @ViewBuilder private var when: some View {
        if later, let d = occ.deadline {
            Text("due \(d.formatted(.dateTime.weekday(.abbreviated))) \(timeString(d))").foregroundStyle(.secondary)
        } else if occ.isOverdue {
            Text("Overdue").foregroundStyle(.red)
        } else if let held = occ.task.heldOver(on: occ.day), !occ.isResolved {
            Text("until \(timeString(held.until))").foregroundStyle(.orange)
        } else if let s = occ.start {
            Text(timeString(s)).foregroundStyle(s < Date() && !occ.isResolved ? .orange : .secondary)
        } else if occ.task.hasSteps {
            let p = occ.task.stepProgress(for: occ)
            Text("\(p.done)/\(p.total)").foregroundStyle(.secondary).help("Steps ticked off")
        } else if occ.task.isHabit {
            Image(systemName: "repeat").foregroundStyle(.secondary)
        }
    }
}
