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

    private static let rowHeight: CGFloat = 26
    private static let maxRows = 12

    var body: some View {
        let items = store.todayChecklist()
        let open = items.filter { !$0.isResolved }
        let settled = items.filter(\.isResolved)
        // Project subtasks on today's list count too.
        let proj = store.projectToday()
        let projOpen = proj.filter { $0.item?.isDone == false }, projDone = proj.filter { $0.item?.isDone == true }
        let done = settled.filter(\.isDone).count + projDone.count
        let openCount = open.count + projOpen.count, total = items.count + proj.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today · \(Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))").font(.headline)
                    Text(total == 0 ? "Nothing scheduled" : openCount == 0 ? "All settled" : "\(openCount) left · \(done) done")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ProgressRing(done: done, total: total, size: 26, lineWidth: 3.5)
            }
            Divider()
            if total == 0 {
                Text("Nothing on today's checklist.").font(.callout).foregroundStyle(.secondary)
                    .frame(height: Self.rowHeight)
            } else {
                if openCount == 0 {
                    Label("Everything's checked off.", systemImage: "checkmark.seal").font(.callout).foregroundStyle(.green)
                        .frame(height: Self.rowHeight)
                } else {
                    rows(open, projOpen)
                }
                if !settled.isEmpty || !projDone.isEmpty {
                    Button { showSettled.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showSettled ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            Text("\(settled.count + projDone.count) settled")
                        }
                        .font(.caption).foregroundStyle(.secondary).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showSettled { rows(settled, projDone) }
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
        .frame(width: 300)
    }

    /// A fixed-height list, scrolling only past `maxRows`.
    @ViewBuilder private func rows(_ occs: [Occurrence], _ proj: [ProjectDeadline] = []) -> some View {
        let list = VStack(spacing: 0) {
            ForEach(occs) { MenuRow(occ: $0).frame(height: Self.rowHeight) }
            ForEach(proj) { MenuProjectRow(d: $0).frame(height: Self.rowHeight) }
        }
        if occs.count + proj.count > Self.maxRows {
            ScrollView { list }.frame(height: Self.rowHeight * CGFloat(Self.maxRows))
        } else {
            list
        }
    }
}

/// A project subtask on today's list: check circle, colour, title, and its deadline (or "urgent").
private struct MenuProjectRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    let d: ProjectDeadline
    @State private var hovering = false

    var body: some View {
        let done = d.item?.isDone == true
        HStack(spacing: 7) {
            Button { store.toggleProjectItem(d) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : hovering ? "checkmark.circle" : "circle")
                    .font(.system(size: 14)).foregroundStyle(done ? d.project.color.color : .secondary)
            }
            .buttonStyle(.plain).help(done ? "Undo" : "Mark done")
            RoundedRectangle(cornerRadius: 1.5).fill(d.project.color.color).frame(width: 3, height: 14)
            Text(d.title.isEmpty ? "Untitled" : d.title).lineLimit(1).truncationMode(.tail)
                .strikethrough(done).foregroundStyle(done ? .secondary : .primary)
            Spacer(minLength: 6)
            Group {
                if d.item?.isUrgent == true && !done { Text("Urgent").foregroundStyle(.red) }
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
        .contextMenu { Button("Open project") { model.openProjectID = d.project.id; model.openChecklist(); model.screen = .projects } }
    }
}

/// One line: check circle, colour, title, and when (time, "until 4:30 PM", overdue).
private struct MenuRow: View {
    @EnvironmentObject private var model: AppModel
    let occ: Occurrence
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
            Spacer(minLength: 6)
            when.font(.caption.monospacedDigit()).lineLimit(1).fixedSize()
        }
        .font(.callout)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { OccurrenceMenu(occ: occ) }
    }

    @ViewBuilder private var when: some View {
        if occ.isOverdue {
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
