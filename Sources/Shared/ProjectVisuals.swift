import SwiftUI

// The project visualizer, shared by the Mac and iPhone apps: a timeline (bars from start to deadline, with
// today marked) and a map (the tree of subtasks drawn left to right).

extension DeadlineStatus {
    var color: Color {
        switch self {
        case .done: return .green
        case .overdue: return .red
        case .today: return .orange
        case .soon: return .yellow
        case .later, .none: return .secondary
        }
    }
    var label: String {
        switch self {
        case .done: return "Done"
        case .overdue: return "Overdue"
        case .today: return "Due today"
        case .soon: return "Due soon"
        case .later: return "On track"
        case .none: return "No deadline"
        }
    }
}

/// A small deadline chip: "Nov 20 · in 5 days", coloured by how close it is.
struct DueChip: View {
    let due: String
    var done = false
    var inherited = false
    var compact = false

    var body: some View {
        let st = DeadlineStatus.of(due: due, done: done)
        HStack(spacing: 3) {
            Image(systemName: inherited ? "arrow.turn.down.right" : "flag.fill").font(.system(size: 8, weight: .bold))
            Text(compact || done ? shortDay(due) : "\(shortDay(due)) · \(dueRelative(due))")
        }
        .font(.caption2.weight(.medium).monospacedDigit())
        .foregroundStyle(inherited ? Color.secondary : st == .later || st == .none ? Color.secondary : st.color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill((inherited || st == .later ? Color.secondary : st.color).opacity(inherited ? 0.08 : 0.14)))
        .help(inherited ? "Uses the deadline above it" : st.label)
    }
}

/// A Gantt chart: one bar per project and per subtask, from its start to its deadline, on a shared day
/// scale with weekends shaded and today marked. Shows one project or several at once.
struct GanttChart: View {
    let projects: [Project]
    /// Collapsed subtasks, and collapsed projects (by project id).
    var collapsed: Set<UUID> = []
    var labelWidth: CGFloat = 230
    var rowHeight: CGFloat = 30
    /// Narrowest a day can get; the chart scrolls sideways past that.
    var minDayWidth: CGFloat = 14
    var selected: UUID?
    var onSelect: ((UUID) -> Void)?
    var onToggleProject: ((UUID) -> Void)?

    enum Line: Identifiable {
        case project(Project)
        case item(Project, Project.Row)
        var id: String {
            switch self {
            case .project(let p): return "p\(p.id)"
            case .item(let p, let r): return "\(p.id)|\(r.id)"
            }
        }
    }

    private var lines: [Line] {
        projects.flatMap { p -> [Line] in
            [.project(p)] + (collapsed.contains(p.id) ? [] : p.rows(collapsed: collapsed).map { .item(p, $0) })
        }
    }

    private struct Span { let lo: Date; let days: Int }

    private func span() -> Span {
        let cal = Calendar.current
        var keys: [String] = []
        for p in projects {
            keys.append(p.startKey)
            if let d = p.due { keys.append(d) }
            for r in p.rows() { keys.append(r.start); if let d = r.due { keys.append(d) } }
        }
        let dates = keys.compactMap(DateKey.date) + [Date().startOfDay]
        let lo = cal.date(byAdding: .day, value: -1, to: dates.min()!)!
        let hi = cal.date(byAdding: .day, value: 3, to: dates.max()!)!
        return Span(lo: lo, days: max(14, cal.dateComponents([.day], from: lo, to: hi).day ?? 14))
    }

    var body: some View {
        let ls = lines, sp = span()
        GeometryReader { geo in
            let chartW = max(geo.size.width - labelWidth, CGFloat(sp.days) * minDayWidth)
            let dayW = chartW / CGFloat(sp.days)
            HStack(alignment: .top, spacing: 0) {
                labels(ls)
                ScrollView(.horizontal, showsIndicators: true) {
                    chart(ls, sp: sp, dayW: dayW).frame(width: chartW)
                }
                // Open with today in view when the chart is wider than the screen.
                .defaultScrollAnchor(UnitPoint(x: todayFraction(sp), y: 0))
            }
        }
        .frame(height: header + CGFloat(ls.count) * rowHeight + 12)
    }

    private var header: CGFloat { rowHeight + 6 }

    private func todayFraction(_ sp: Span) -> Double {
        let n = Calendar.current.dateComponents([.day], from: sp.lo, to: Date().startOfDay).day ?? 0
        return min(1, max(0, (Double(n) - 3) / Double(sp.days)))
    }

    private func labels(_ ls: [Line]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Project / subtask").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(height: header, alignment: .bottomLeading).padding(.leading, 4).padding(.bottom, 0)
            ForEach(ls) { line in
                switch line {
                case .project(let p):
                    HStack(spacing: 5) {
                        Image(systemName: collapsed.contains(p.id) ? "chevron.right" : "chevron.down").font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary).frame(width: 10)
                        RoundedRectangle(cornerRadius: 2).fill(p.color.color).frame(width: 4, height: 14)
                        Text(p.title.isEmpty ? "Untitled project" : p.title).font(.callout.weight(.semibold)).lineLimit(1)
                    }
                    .padding(.leading, 2)
                    .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                    .background(p.color.color.opacity(0.08))
                    .contentShape(Rectangle())
                    .onTapGesture { onToggleProject?(p.id) }
                case .item(_, let r):
                    HStack(spacing: 4) {
                        Image(systemName: r.item.isDone ? "checkmark.circle.fill" : r.item.items.isEmpty ? "circle" : "circle.dashed")
                            .font(.system(size: 10)).foregroundStyle(r.item.isDone ? Color.green : .secondary)
                        Text(r.item.title.isEmpty ? "Untitled" : r.item.title)
                            .font(r.depth == 0 ? .callout.weight(.medium) : .callout)
                            .foregroundStyle(r.item.isDone ? .secondary : .primary)
                            .lineLimit(1)
                        if r.item.isUrgent && !r.item.isDone {
                            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(.red).help("Urgent")
                        }
                    }
                    .padding(.leading, CGFloat(r.depth) * 14 + 16)
                    .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                    .background(selected == r.id ? Color.accentColor.opacity(0.12) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect?(r.id) }
                }
            }
        }
        .frame(width: labelWidth, alignment: .leading)
    }

    private func chart(_ ls: [Line], sp: Span, dayW: CGFloat) -> some View {
        let cal = Calendar.current
        func x(_ key: String) -> CGFloat {
            guard let d = DateKey.date(key) else { return 0 }
            return CGFloat(cal.dateComponents([.day], from: sp.lo, to: d).day ?? 0) * dayW
        }
        let todayKey = DateKey.string(Date())
        let height = header + CGFloat(ls.count) * rowHeight
        return Canvas { ctx, size in
            // Grid: weekends shaded, a line each Monday (and each day when there's room), months along the top.
            for i in 0...sp.days {
                let d = cal.date(byAdding: .day, value: i, to: sp.lo)!
                let px = CGFloat(i) * dayW
                let wd = cal.component(.weekday, from: d)
                let monday = wd == 2, first = cal.component(.day, from: d) == 1
                if (wd == 1 || wd == 7) && i < sp.days {
                    ctx.fill(Path(CGRect(x: px, y: header - 4, width: dayW, height: size.height)), with: .color(.secondary.opacity(0.06)))
                }
                if monday || first || dayW >= 22 {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: header - 4)); $0.addLine(to: CGPoint(x: px, y: size.height)) },
                               with: .color(.secondary.opacity(first ? 0.45 : monday ? 0.22 : 0.08)), lineWidth: 1)
                }
                if first || i == 0 {
                    ctx.draw(Text(d.formatted(.dateTime.month(.abbreviated))).font(.caption2.weight(.semibold)).foregroundStyle(.secondary),
                             at: CGPoint(x: px + 3, y: 6), anchor: .topLeading)
                }
                if monday || dayW >= 22 {
                    ctx.draw(Text("\(cal.component(.day, from: d))").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary),
                             at: CGPoint(x: px + dayW / 2, y: header - 8), anchor: .center)
                }
            }
            func diamond(_ cx: CGFloat, _ cy: CGFloat, _ s: CGFloat) -> Path {
                Path { $0.move(to: CGPoint(x: cx, y: cy - s)); $0.addLine(to: CGPoint(x: cx + s, y: cy))
                    $0.addLine(to: CGPoint(x: cx, y: cy + s)); $0.addLine(to: CGPoint(x: cx - s, y: cy)); $0.closeSubpath() }
            }
            func bar(start: String, due: String, y: CGFloat, inset: CGFloat, tint: Color, fill: Double, progress: (done: Int, total: Int), dashed: Bool) -> CGFloat {
                let x0 = min(x(start), x(due)), x1 = x(due) + dayW
                let rect = CGRect(x: x0 + 1, y: y + inset, width: max(dayW - 2, x1 - x0 - 2), height: rowHeight - inset * 2)
                let shape = Path(roundedRect: rect, cornerRadius: min(6, rect.height / 2))
                ctx.fill(shape, with: .color(tint.opacity(fill)))
                if progress.total > 0, progress.done > 0 {
                    var c = ctx
                    c.clip(to: shape)
                    c.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(progress.done) / CGFloat(progress.total), height: rect.height)),
                           with: .color(tint.opacity(0.55)))
                }
                if dashed { ctx.stroke(shape, with: .color(.red), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])) }
                return x1
            }
            for (i, line) in ls.enumerated() {
                let y = header + CGFloat(i) * rowHeight
                switch line {
                case .project(let p):
                    ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: rowHeight)), with: .color(p.color.color.opacity(0.06)))
                    let latest = p.rows().compactMap(\.due).max()
                    guard let due = p.due ?? latest else { continue }
                    let x1 = bar(start: p.startKey, due: due, y: y, inset: 9, tint: p.color.color, fill: 0.25, progress: p.progress, dashed: false)
                    let pr = p.progress
                    if p.due != nil { ctx.fill(diamond(x1 - dayW / 2, y + rowHeight / 2, 7), with: .color(p.color.color)) }
                    ctx.draw(Text(pr.total > 0 ? "\(shortDay(due)) · \(Int((Double(pr.done) / Double(pr.total) * 100).rounded()))%" : shortDay(due))
                                .font(.system(size: 9, weight: .bold).monospacedDigit()).foregroundStyle(p.color.color),
                             at: CGPoint(x: x1 - dayW / 2 + 10, y: y + rowHeight / 2), anchor: .leading)
                case .item(let p, let r):
                    let done = r.item.isDone
                    let st = DeadlineStatus.of(due: r.due, done: done, today: todayKey)
                    let tint: Color = done ? .green : st == .overdue ? .red : st == .today || r.item.isUrgent ? .orange : p.color.color
                    guard let due = r.due else {
                        ctx.fill(Path(ellipseIn: CGRect(x: x(r.start) + dayW / 2 - 3, y: y + rowHeight / 2 - 3, width: 6, height: 6)),
                                 with: .color(.secondary.opacity(0.5)))
                        continue
                    }
                    let x1 = bar(start: r.start, due: due, y: y, inset: 8, tint: tint, fill: r.dueIsOwn ? 0.22 : 0.1,
                                 progress: r.item.progress, dashed: r.conflict)
                    if r.dueIsOwn {
                        let cx = x1 - dayW / 2, cy = y + rowHeight / 2
                        ctx.fill(diamond(cx, cy, 6), with: .color(tint))
                        ctx.draw(Text(shortDay(due)).font(.system(size: 9, weight: .medium).monospacedDigit()).foregroundStyle(tint),
                                 at: CGPoint(x: cx + 9, y: cy), anchor: .leading)
                    }
                    if selected == r.id {
                        ctx.stroke(Path(CGRect(x: 0, y: y, width: size.width, height: rowHeight)), with: .color(.accentColor.opacity(0.6)), lineWidth: 1)
                    }
                }
            }
            // One project: its deadline as a dashed line down the chart.
            if projects.count == 1, let p = projects.first, let d = p.due {
                let px = x(d) + dayW
                ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: header - 4)); $0.addLine(to: CGPoint(x: px, y: size.height)) },
                           with: .color(p.color.color.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                ctx.draw(Text("deadline").font(.system(size: 9, weight: .semibold)).foregroundStyle(p.color.color),
                         at: CGPoint(x: px - 3, y: 6), anchor: .topTrailing)
            }
            // Today.
            let tx = x(todayKey) + dayW / 2
            ctx.stroke(Path { $0.move(to: CGPoint(x: tx, y: header - 14)); $0.addLine(to: CGPoint(x: tx, y: size.height)) },
                       with: .color(.red.opacity(0.85)), lineWidth: 1.5)
            ctx.fill(Path(ellipseIn: CGRect(x: tx - 3.5, y: header - 17.5, width: 7, height: 7)), with: .color(.red))
        }
        .frame(height: height)
    }
}

/// The tree of subtasks drawn left to right: the project, its subtasks, their subtasks, and so on.
struct ProjectMap: View {
    let project: Project
    var collapsed: Set<UUID> = []
    var nodeWidth: CGFloat = 176
    var selected: UUID?
    var onSelect: ((UUID) -> Void)?

    private let colGap: CGFloat = 44
    private let rowHeight: CGFloat = 62

    var body: some View {
        let lay = ProjectMapLayout(project, collapsed: collapsed)
        let w = CGFloat(lay.depth + 1) * (nodeWidth + colGap) + 20
        let h = CGFloat(lay.rows) * rowHeight + 20
        let pos: [String: CGPoint] = Dictionary(uniqueKeysWithValues: lay.nodes.map {
            (key($0.id), CGPoint(x: 10 + CGFloat($0.depth) * (nodeWidth + colGap) + nodeWidth / 2, y: 10 + CGFloat($0.y) * rowHeight + rowHeight / 2))
        })
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in
                    for e in lay.edges {
                        guard let a = pos[key(e.from)], let b = pos[key(e.to)] else { continue }
                        let from = CGPoint(x: a.x + nodeWidth / 2, y: a.y), to = CGPoint(x: b.x - nodeWidth / 2, y: b.y)
                        let done = e.to.flatMap { project.item($0) }?.isDone == true
                        let mid = (from.x + to.x) / 2
                        ctx.stroke(Path { $0.move(to: from); $0.addCurve(to: to, control1: CGPoint(x: mid, y: from.y), control2: CGPoint(x: mid, y: to.y)) },
                                   with: .color(done ? Color.green.opacity(0.6) : Color.secondary.opacity(0.45)), lineWidth: 1.5)
                    }
                }
                .frame(width: w, height: h)
                ForEach(lay.nodes) { n in
                    node(n).frame(width: nodeWidth).position(pos[key(n.id)] ?? .zero)
                }
            }
            .frame(width: w, height: h)
        }
        .frame(height: h + 12)
    }

    private func key(_ id: UUID?) -> String { id?.uuidString ?? "root" }

    @ViewBuilder private func node(_ n: ProjectMapLayout.Node) -> some View {
        if let item = n.item {
            let p = item.progress
            let st = DeadlineStatus.of(due: item.due, done: item.isDone)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: item.isDone ? "checkmark.circle.fill" : item.items.isEmpty ? "circle" : "circle.dashed")
                        .font(.system(size: 11)).foregroundStyle(item.isDone ? Color.green : .secondary)
                    Text(item.title.isEmpty ? "Untitled" : item.title).font(.caption.weight(.medium)).lineLimit(1)
                        .foregroundStyle(item.isDone ? .secondary : .primary)
                    if item.isUrgent && !item.isDone {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(.red)
                    }
                    if collapsed.contains(item.id) && !item.items.isEmpty {
                        Text("+\(item.items.count)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    if item.items.count > 0 {
                        ProgressView(value: Double(p.done), total: Double(max(1, p.total))).tint(project.color.color).frame(maxWidth: .infinity)
                        Text("\(p.done)/\(p.total)").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary)
                    } else {
                        Spacer(minLength: 0)
                    }
                    if let d = item.due { DueChip(due: d, done: item.isDone, compact: true) }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected == item.id ? Color.accentColor
                     : st == .overdue || st == .today ? st.color.opacity(0.8) : Color.secondary.opacity(0.3), lineWidth: selected == item.id ? 2 : 1))
            .contentShape(Rectangle())
            .onTapGesture { onSelect?(item.id) }
        } else {
            let p = project.progress
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title.isEmpty ? "Untitled project" : project.title).font(.callout.weight(.semibold)).lineLimit(2)
                HStack(spacing: 6) {
                    ProgressView(value: Double(p.done), total: Double(max(1, p.total))).tint(.white)
                    Text("\(p.done)/\(p.total)").font(.system(size: 9).monospacedDigit())
                }
                if let d = project.due { Text("Due \(shortDay(d)) · \(dueRelative(d))").font(.caption2) }
            }
            .foregroundStyle(.white)
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 10).fill(project.color.color.gradient))
        }
    }
}
