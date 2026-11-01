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
        let done = settled.filter(\.isDone).count
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today · \(Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))").font(.headline)
                    Text(items.isEmpty ? "Nothing scheduled" : open.isEmpty ? "All settled" : "\(open.count) left · \(done) done")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ProgressRing(done: done, total: items.count, size: 26, lineWidth: 3.5)
            }
            Divider()
            if items.isEmpty {
                Text("Nothing on today's checklist.").font(.callout).foregroundStyle(.secondary)
                    .frame(height: Self.rowHeight)
            } else {
                if open.isEmpty {
                    Label("Everything's checked off.", systemImage: "checkmark.seal").font(.callout).foregroundStyle(.green)
                        .frame(height: Self.rowHeight)
                } else {
                    rows(open)
                }
                if !settled.isEmpty {
                    Button { showSettled.toggle() } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showSettled ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            Text("\(settled.count) settled")
                        }
                        .font(.caption).foregroundStyle(.secondary).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if showSettled { rows(settled) }
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
    @ViewBuilder private func rows(_ occs: [Occurrence]) -> some View {
        let list = VStack(spacing: 0) { ForEach(occs) { MenuRow(occ: $0).frame(height: Self.rowHeight) } }
        if occs.count > Self.maxRows {
            ScrollView { list }.frame(height: Self.rowHeight * CGFloat(Self.maxRows))
        } else {
            list
        }
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
        } else if occ.task.isHabit {
            Image(systemName: "repeat").foregroundStyle(.secondary)
        }
    }
}
