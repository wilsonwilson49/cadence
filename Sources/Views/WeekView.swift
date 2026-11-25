import SwiftUI

struct WeekView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var google: GoogleCalendar
    @State private var weekStart = Date().startOfWeek
    /// The time you spent focusing, working and studying, as a strip down each day (and totals in the headers).
    @AppStorage("weekShowFocus") private var showFocus = true

    private let hourHeight: CGFloat = 48
    private let gutter: CGFloat = 56
    /// Room for the focus strip at the left of each day.
    private var lane: CGFloat { showFocus ? 6 : 0 }

    private var weekFocus: (focus: Int, study: Int) {
        days.reduce(into: (0, 0)) { t, d in let m = store.focusMinutes(on: d); t.0 += m.focus; t.1 += m.study }
    }
    private var subtitle: String {
        let w = weekFocus
        guard showFocus, w.focus + w.study > 0 else { return "Double-click an empty slot to add a task there." }
        let parts = [w.focus > 0 ? "\(Focus.label(w.focus)) focused" : nil, w.study > 0 ? "\(Focus.label(w.study)) studied" : nil].compactMap { $0 }
        return "\(parts.joined(separator: ", ")) this week. Double-click an empty slot to add a task."
    }

    private var days: [Date] { (0..<7).map { weekStart.adding(days: $0) } }

    private var title: String {
        let end = weekStart.adding(days: 6)
        let sameMonth = Calendar.current.isDate(weekStart, equalTo: end, toGranularity: .month)
        let a = weekStart.formatted(.dateTime.month(.abbreviated).day())
        let b = sameMonth ? end.formatted(.dateTime.day()) : end.formatted(.dateTime.month(.abbreviated).day())
        return "\(a) – \(b), \(end.formatted(.dateTime.year()))"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: title, subtitle: subtitle) {
                Toggle(isOn: $showFocus) { Label("Focus time", systemImage: "scope") }
                    .toggleStyle(.button)
                    .help("Show the time you spent focusing (purple), working on a task (blue) and studying (green) down the left of each day")
                Toggle(isOn: $model.weekSelecting) { Label("Select", systemImage: "checkmark.circle") }
                    .toggleStyle(.button)
                    .help("Pick several tasks to change them all at once. You can also ⌘-click or ⇧-click tasks any time.")
                CalendarsMenu()
                Button { model.newEvent(on: weekStart.isSameDay(Date().startOfWeek) ? Date() : weekStart) } label: {
                    Label("New Event", systemImage: "calendar.badge.plus")
                }
                CalendarNav(onPrev: { weekStart = weekStart.adding(days: -7) },
                            onToday: { weekStart = Date().startOfWeek },
                            onNext: { weekStart = weekStart.adding(days: 7) })
            }
            if model.weekSelecting || !model.weekSelection.isEmpty { WeekSelectionBar(days: days) }
            GeometryReader { geo in
                let colW = max(60, (geo.size.width - gutter - 8) / 7)
                VStack(spacing: 0) {
                    dayHeader(colW)
                    allDayRow(colW)
                        .onContinuousHover { phase in
                            if case .active(let p) = phase {
                                let i = Int((p.x - gutter) / colW)
                                model.weekHoverPoint = days.indices.contains(i) && p.x >= gutter ? (days[i], nil) : nil
                            } else { model.weekHoverPoint = nil }
                        }
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            ZStack(alignment: .topLeading) {
                                hourGrid(colW)
                                if showFocus { focusLayer(colW) }
                                ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                                    ForEach(placed(day)) { p in
                                        TimedBlock(item: p.item, height: max(20, p.height(hourHeight)))
                                            .frame(width: (colW - lane) / CGFloat(p.lanes) - 3,
                                                   height: max(20, p.height(hourHeight)))
                                            .offset(x: gutter + CGFloat(i) * colW + lane + CGFloat(p.lane) * (colW - lane) / CGFloat(p.lanes) + 1.5,
                                                    y: p.y(hourHeight))
                                    }
                                }
                                nowLine(colW)
                            }
                            .frame(height: hourHeight * 24, alignment: .topLeading)
                            .onContinuousHover { phase in
                                if case .active(let p) = phase {
                                    let i = Int((p.x - gutter) / colW)
                                    model.weekHoverPoint = days.indices.contains(i) && p.x >= gutter ? (days[i], min(1425, max(0, Int(p.y / hourHeight * 4) * 15))) : nil
                                } else { model.weekHoverPoint = nil }
                            }
                            .environment(\.calendarGrid, CalendarGrid(hourHeight: hourHeight, dayWidth: colW))
                        }
                        .onAppear { proxy.scrollTo(7, anchor: .top) }
                    }
                }
            }
        }
        .modifier(WeekBandPicker())
        .modifier(WeekKeys())
        .onAppear { google.ensure(from: weekStart, to: weekStart.adding(days: 7)) }
        .onChange(of: weekStart) { _, new in google.ensure(from: new, to: new.adding(days: 7)) }
    }

    // MARK: Pieces

    private func dayHeader(_ colW: CGFloat) -> some View {
        HStack(spacing: 0) {
            Spacer().frame(width: gutter, height: 1)
            ForEach(days, id: \.self) { day in
                let isToday = day.isToday
                VStack(spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                        .font(.app(.caption2).weight(.semibold)).foregroundStyle(.secondary)
                    Text(day.formatted(.dateTime.day()))
                        .font(.app(.title3).weight(isToday ? .bold : .regular))
                        .foregroundStyle(isToday ? .white : .primary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(isToday ? Color.accentColor : .clear))
                    let open = store.checklist(on: day).filter { !$0.isResolved }.count
                    Text(open > 0 ? "\(open) open" : " ")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    if showFocus {
                        let m = store.focusMinutes(on: day)
                        Group {
                            if m.focus + m.study > 0 {
                                Label(Focus.label(m.focus + m.study), systemImage: "scope").labelStyle(CompactLabelStyle())
                                    .foregroundStyle(Color.accentColor)
                                    .help([m.focus > 0 ? "Focused \(Focus.label(m.focus))" : nil, m.study > 0 ? "studied \(Focus.label(m.study))" : nil].compactMap { $0 }.joined(separator: ", "))
                            } else { Text(" ") }
                        }
                        .font(.system(size: 9))
                    }
                }
                .frame(width: colW)
            }
        }
        .padding(.bottom, 4)
    }

    private func allDayRow(_ colW: CGFloat) -> some View {
        let columns: [[CalendarItem]] = days.map { day in
            google.visibleOccurrences(on: day).filter { $0.start == nil && (!$0.isUntilDone || $0.isUntilDoneWeekDay) }.map(CalendarItem.task)
                + google.visibleEvents(on: day).filter(\.isAllDay).map(CalendarItem.google)
        }
        let rows = min(4, columns.map(\.count).max() ?? 0)
        return HStack(alignment: .top, spacing: 0) {
            Text("any\ntime").font(.system(size: 9)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                .frame(width: gutter - 8, alignment: .trailing).padding(.trailing, 8)
            ForEach(Array(columns.enumerated()), id: \.offset) { _, items in
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items.prefix(rows == 4 && items.count > 4 ? 3 : 4)) { ItemChip(item: $0) }
                    if items.count > 4 {
                        Text("+\(items.count - 3) more").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: colW - 4, alignment: .topLeading)
                .padding(.horizontal, 2)
            }
        }
        .frame(minHeight: rows == 0 ? 22 : CGFloat(rows) * 19 + 6, alignment: .top)
        .padding(.vertical, 3)
    }

    private func hourGrid(_ colW: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { h in
                    HStack(alignment: .top, spacing: 0) {
                        Text(h == 0 ? "" : timeString(minutes: h * 60))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(width: gutter - 8, alignment: .trailing)
                            .offset(y: -6)
                            .padding(.trailing, 8)
                        VStack(spacing: 0) {
                            Divider()
                            Spacer()
                        }
                    }
                    .frame(height: hourHeight)
                    .id(h)
                }
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: gutter)
                ForEach(days, id: \.self) { day in
                    Rectangle()
                        .fill(day.isToday ? Color.accentColor.opacity(0.04) : Color.clear)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1) }
                        .frame(width: colW)
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture(count: 2).onEnded { v in
                            let minutes = Int(v.location.y / hourHeight * 60) / 30 * 30
                            model.newTask(on: day, minutes: min(minutes, 23 * 60 + 30))
                        })
                }
            }
        }
    }

    /// Focus, work and study sessions as a thin strip down the left of each day; hover one for what and how long.
    private func focusLayer(_ colW: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(days.enumerated()), id: \.offset) { i, day in
                ForEach(store.focusBlocks(on: day)) { b in focusMark(b, column: i, colW: colW) }
            }
            // The session running now, refreshed every half minute.
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                if model.focus.running, let i = days.firstIndex(where: \.isToday) {
                    // Pauses are gaps, like on finished sessions.
                    ForEach(Array(model.focus.liveSegments.enumerated()), id: \.offset) { n, seg in
                        let live = FocusBlock(id: "live-\(n)", start: seg.start, end: max(seg.end, seg.start.addingTimeInterval(60)), kind: model.focus.isWorking ? .work : .focus,
                                              title: (model.focus.workOccurrence?.task.title ?? "Focus sprint") + (model.focus.isPaused ? " (paused)" : " (now)"))
                        focusMark(live, column: i, colW: colW)
                    }
                }
            }
        }
    }

    private func focusMark(_ b: FocusBlock, column i: Int, colW: CGFloat) -> some View {
        let y = CGFloat(b.start.minutesSinceMidnight) / 60 * hourHeight + CGFloat(Calendar.current.component(.second, from: b.start)) / 3600 * hourHeight
        let h = max(3, CGFloat(b.end.timeIntervalSince(b.start)) / 3600 * hourHeight)
        return RoundedRectangle(cornerRadius: 2).fill(b.kind.color.opacity(0.85))
            .frame(width: 4, height: h)
            .offset(x: gutter + CGFloat(i) * colW + 2, y: y)
            .help("\(b.kind.title): \(b.title) · \(timeString(b.start))–\(timeString(b.end)) (\(TaskStats.format(b.minutes)))")
    }

    @ViewBuilder private func nowLine(_ colW: CGFloat) -> some View {
        if let i = days.firstIndex(where: \.isToday) {
            let y = CGFloat(Date().minutesSinceMidnight) / 60 * hourHeight
            HStack(spacing: 0) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Rectangle().fill(.red).frame(width: colW - 8, height: 1.5)
            }
            .offset(x: gutter + CGFloat(i) * colW - 4, y: y - 4)
            .allowsHitTesting(false)
        }
    }

    // MARK: Layout of overlapping items

    struct Placed: Identifiable {
        let item: CalendarItem
        let start: Date
        let end: Date
        let day: Date
        var lane = 0
        var lanes = 1
        var id: String { item.id }

        func y(_ hh: CGFloat) -> CGFloat {
            CGFloat(max(0, start.timeIntervalSince(day.startOfDay)) / 3600) * hh
        }
        func height(_ hh: CGFloat) -> CGFloat {
            let s = max(start, day.startOfDay)
            let e = min(end, day.startOfDay.adding(days: 1))
            return CGFloat(e.timeIntervalSince(s) / 3600) * hh
        }
    }

    private func placed(_ day: Date) -> [Placed] {
        var items: [Placed] = []
        for occ in google.visibleOccurrences(on: day) where !occ.isUntilDone || occ.isUntilDoneWeekDay {
            if let s = occ.start, let e = occ.end { items.append(Placed(item: .task(occ), start: s, end: e, day: day)) }
        }
        for ev in google.visibleEvents(on: day) where !ev.isAllDay {
            items.append(Placed(item: .google(ev), start: ev.start, end: ev.end, day: day))
        }
        items.sort { ($0.start, $1.end) < ($1.start, $0.end) }

        // Greedy lane assignment within clusters of overlapping items.
        var result: [Placed] = []
        var cluster: [Placed] = []
        var laneEnds: [Date] = []
        var clusterEnd = Date.distantPast
        func flush() {
            let n = max(1, laneEnds.count)
            result += cluster.map { var p = $0; p.lanes = n; return p }
            cluster = []; laneEnds = []
        }
        for var p in items {
            if p.start >= clusterEnd { flush() }
            if let free = laneEnds.firstIndex(where: { $0 <= p.start }) {
                p.lane = free; laneEnds[free] = p.end
            } else {
                p.lane = laneEnds.count; laneEnds.append(p.end)
            }
            clusterEnd = max(clusterEnd, p.end)
            cluster.append(p)
        }
        flush()
        return result
    }
}

/// The scale of a calendar grid, so its blocks can be dragged to a new time (and day) or resized.
struct CalendarGrid { var hourHeight: CGFloat; var dayWidth: CGFloat }
private struct CalendarGridKey: EnvironmentKey { static let defaultValue: CalendarGrid? = nil }
extension EnvironmentValues {
    var calendarGrid: CalendarGrid? {
        get { self[CalendarGridKey.self] }
        set { self[CalendarGridKey.self] = newValue }
    }
}

struct TimedBlock: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.calendarGrid) private var grid
    let item: CalendarItem
    let height: CGFloat
    @State private var showing = false
    @State private var drag: CGSize = .zero
    @State private var stretch: CGFloat = 0

    /// Snapped change from a drag: whole days sideways, 15-minute steps up and down.
    private func steps(_ t: CGSize) -> (days: Int, minutes: Int) {
        guard let g = grid else { return (0, 0) }
        return (Int((t.width / g.dayWidth).rounded()), Int((t.height / g.hourHeight * 4).rounded()) * 15)
    }
    private var canMove: Bool {
        guard grid != nil, item.start != nil else { return false }
        if case .task(let o) = item { return !o.isDone && !o.isMissed && !o.isUntilDone }
        return true
    }
    private var dragLabel: String? {
        guard let s = item.start, let e = item.end else { return nil }
        if drag != .zero {
            let st = steps(drag), ns = s.adding(days: st.days).adding(minutes: st.minutes)
            return "\(st.days != 0 ? ns.formatted(.dateTime.weekday(.abbreviated)) + " " : "")\(timeString(ns))–\(timeString(ns.addingTimeInterval(e.timeIntervalSince(s))))"
        }
        if stretch != 0, let g = grid {
            let m = max(15, Int((e.timeIntervalSince(s) / 60 + Double(stretch / g.hourHeight * 60)) / 15) * 15)
            return "\(timeString(s))–\(timeString(s.adding(minutes: m))) · \(m) min"
        }
        return nil
    }

    /// The clock time at a vertical position inside the block.
    private func moment(atY y: CGFloat) -> Date? {
        guard let s = item.start, let e = item.end else { return nil }
        let f = min(max(y / max(height, 1), 0), 1)
        return s.addingTimeInterval(e.timeIntervalSince(s) * f)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                if item.isUntilDone {
                    Image(systemName: "flame.fill").font(.system(size: 9)).foregroundStyle(.orange)
                } else if item.isCalendarEvent {
                    Image(systemName: "calendar").font(.system(size: 8, weight: .bold))
                } else if item.isDone {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 9))
                } else if item.isMissed {
                    Image(systemName: "xmark.square.fill").font(.system(size: 9)).foregroundStyle(.red)
                }
                Text(item.title).font(.system(size: 11, weight: .semibold)).lineLimit(2)
                    .strikethrough(item.isDone || item.isMissed, color: item.isMissed ? .red : nil)
            }
            if let s = item.start {
                Text(timeString(s)).font(.system(size: 10)).opacity(0.75)
            }
        }
        .foregroundStyle(item.isDone || item.isMissed ? Color.secondary : Color.primary)
        .padding(.leading, 6)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(item.color.opacity(item.isDone ? 0.10 : (item.isCalendarEvent ? 0.14 : 0.24)))
        .background { if !item.isBusy { OpenStripes(color: item.color) } }
        .overlay(alignment: .leading) {
            // Open items (just for info) get a dotted edge and stripes, so closed ones read as "taken".
            if item.isBusy { Rectangle().fill(item.color).frame(width: 3) }
            else { Rectangle().stroke(item.color, style: StrokeStyle(lineWidth: 3, dash: [2, 2])).frame(width: 1.5) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay { if model.weekSelection[item.occID ?? ""] != nil { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2.5) } }
        .reportWeekFrame(item)
        .onHover { model.weekHover(item, $0) }
        .contentShape(Rectangle())
        // Double-click inside a block adds a task at that exact time; single click shows details.
        .gesture(
            SpatialTapGesture(count: 2)
                .onEnded { v in if let m = moment(atY: v.location.y) { model.newTask(at: m) } }
                .exclusively(before: TapGesture().onEnded { if !model.weekPick(item) { showing = true } })
        )
        .overlay(alignment: .bottom) {
            // Drag the bottom edge to change how long it is.
            if canMove {
                Color.clear.frame(height: 6).contentShape(Rectangle())
                    .onHover { h in if h { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { stretch = $0.translation.height }
                        .onEnded { v in
                            if let s = item.start, let e = item.end, let g = grid {
                                let m = max(15, Int((e.timeIntervalSince(s) / 60 + Double(v.translation.height / g.hourHeight * 60)) / 15) * 15)
                                model.applyEdit(item, minutes: m)
                            }
                            stretch = 0
                        })
            }
        }
        .overlay(alignment: .top) {
            if stretch != 0 {
                RoundedRectangle(cornerRadius: 5).strokeBorder(item.color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(height: max(12, height + stretch)).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let l = dragLabel {
                Text(l).font(.system(size: 10, weight: .bold).monospacedDigit()).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .fixedSize().offset(y: -18).allowsHitTesting(false)
            }
        }
        .offset(drag)
        .zIndex(drag == .zero && stretch == 0 ? 0 : 10)
        .simultaneousGesture(DragGesture(minimumDistance: 6)
            .onChanged { v in if canMove && !NSEvent.modifierFlags.contains(.shift) { drag = v.translation } }
            .onEnded { v in
                guard canMove, drag != .zero, let s = item.start else { drag = .zero; return }
                let st = steps(v.translation)
                drag = .zero
                if st.days != 0 || st.minutes != 0 { model.applyEdit(item, start: s.adding(days: st.days).adding(minutes: st.minutes)) }
            })
        .help("\(item.isBusy ? "Closed" : "Open (just for info)") · click for details and quick edits\(canMove ? " · drag to move it, drag its bottom edge to change its length" : "") · double-click to add a task at this time")
        .contextMenu { AddDuringMenu(item: item) }
        .popover(isPresented: $showing, arrowEdge: .trailing) { ItemDetail(item: item) { showing = false } }
    }
}

/// Until-done tasks in the week as one bar per stretch of days (a new bar when the next repeat takes over),
/// so they don't fill every day's "any time" cell.
struct UntilDoneStrip: View {
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var google: GoogleCalendar
    let days: [Date]
    let colW: CGFloat
    let gutter: CGFloat

    struct Span: Identifiable {
        let task: PlanTask
        let rep: Date
        var start: Int
        var end: Int
        var before: Bool
        var after = false
        var id: String { "\(task.id)|\(start)" }
    }

    private var spans: [Span] {
        var out: [Span] = []
        for t in store.tasks where t.isUntilDone && !t.isEvent && t.archived != true && google.isShown(t) {
            var current: Int?
            for (i, d) in days.enumerated() {
                guard t.untilDoneActive(on: d), let rep = t.currentRepStart(on: d) else { current = nil; continue }
                if let c = current, out[c].rep == rep, out[c].end == i - 1 { out[c].end = i; continue }
                out.append(Span(task: t, rep: rep, start: i, end: i, before: i == 0 && rep < d.startOfDay))
                current = out.count - 1
            }
        }
        for i in out.indices where out[i].end == 6 {
            let next = days[6].adding(days: 1)
            out[i].after = out[i].task.untilDoneActive(on: next) && out[i].task.repStart(on: next) == out[i].rep
        }
        return out.sorted { ($0.start, $1.end - $1.start) < ($1.start, $0.end - $0.start) }
    }

    var body: some View {
        // Bars that don't overlap share a row.
        var rows: [[Span]] = []
        for s in spans {
            if let i = rows.firstIndex(where: { ($0.last?.end ?? -1) < s.start }) { rows[i].append(s) } else { rows.append([s]) }
        }
        return Group {
            if !rows.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                Text("until\ndone").font(.system(size: 9)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                    .frame(width: gutter - 8, alignment: .trailing).padding(.trailing, 8)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        ZStack(alignment: .leading) {
                            ForEach(row) { s in bar(s) }
                        }
                        .frame(width: colW * 7, alignment: .leading)
                    }
                }
                .frame(width: colW * 7, alignment: .leading)
            }
            .padding(.vertical, 4)
            Divider()
            }
        }
    }

    private func bar(_ s: Span) -> some View {
        let todayIndex = days.firstIndex(where: \.isToday)
        let day = todayIndex.flatMap { ($0 >= s.start && $0 <= s.end) ? days[$0] : nil } ?? days[s.end]
        let last = Occurrence(task: s.task, day: days[s.end])
        let color = s.task.color.color
        return SpanBar(occ: Occurrence(task: s.task, day: day), days: s.end - s.start + 1, done: last.isDone, missed: last.isMissed,
                       before: s.before, after: s.after, color: color)
            .frame(width: colW * CGFloat(s.end - s.start + 1) - (s.before || s.after ? 3 : 6))
            .offset(x: colW * CGFloat(s.start) + (s.before ? 0 : 3))
    }
}

private struct SpanBar: View {
    let occ: Occurrence
    let days: Int
    let done: Bool
    let missed: Bool
    let before: Bool
    let after: Bool
    let color: Color
    @State private var showing = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: done ? "checkmark" : missed ? "xmark" : "flame").font(.system(size: 9, weight: .bold)).foregroundStyle(color)
            Text(occ.task.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                .strikethrough(done || missed, color: missed ? .red : nil)
            Spacer(minLength: 4)
            if days > 1 { Text("\(days) days").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.2))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: before ? 0 : 6, bottomLeadingRadius: before ? 0 : 6,
                                          bottomTrailingRadius: after ? 0 : 6, topTrailingRadius: after ? 0 : 6))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: before ? 0 : 6, bottomLeadingRadius: before ? 0 : 6,
                                        bottomTrailingRadius: after ? 0 : 6, topTrailingRadius: after ? 0 : 6)
            .strokeBorder(color.opacity(0.55), lineWidth: 1))
        .opacity(done || missed ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { showing = true }
        .help("\(occ.task.title) · \(occ.task.planSummary ?? "")")
        .popover(isPresented: $showing, arrowEdge: .bottom) { ItemDetail(item: .task(occ)) { showing = false } }
    }
}

/// Week calendar: what's picked, and changes for all of them at once.
struct WeekSelectionBar: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var google: GoogleCalendar
    let days: [Date]
    @State private var confirmDeleteAll = false
    @State private var checkingOff = false
    @State private var reflection = ""

    private var picked: [Occurrence] { Array(model.weekSelection.values) }
    private var taskIDs: Set<UUID> { Set(picked.map(\.task.id)) }

    var body: some View {
        HStack(spacing: 8) {
            Text(picked.isEmpty ? "Click tasks to pick them, or pick a whole day:" : "\(picked.count) picked")
                .font(.app(.callout).weight(.semibold))
            if picked.isEmpty {
                ForEach(days, id: \.self) { d in
                    Button(d.formatted(.dateTime.weekday(.abbreviated))) { pickDay(d) }.controlSize(.small)
                }
                Button("Whole week") { days.forEach(pickDay) }.controlSize(.small)
            } else {
                Button { checkingOff = true } label: { Label("Check off", systemImage: "checkmark.circle") }
                Menu {
                    Button("Keep on checklist until done") { editTasks { $0.mode = "untilDone" } }
                    Button("Just on its day (not until done)") { editTasks { $0.mode = nil; $0.dueDate = nil } }
                    Divider()
                    Button("Mark urgent") { editTasks { $0.urgent = true } }
                    Button("Not urgent") { editTasks { $0.urgent = nil } }
                    Divider()
                    Menu("Color") { ForEach(TaskColor.allCases) { c in Button(c.rawValue.capitalized) { editTasks { $0.color = c } } } }
                    Menu("Priority") {
                        ForEach(Priority.allCases) { p in Button(p.title) { editTasks { $0.priority = p.rawValue } } }
                        Button("None") { editTasks { $0.priority = nil } }
                    }
                    Menu("Hardness") {
                        ForEach(Hardness.range, id: \.self) { n in Button("\(n) · \(Hardness.title(n))") { editTasks { $0.hardness = n } } }
                        Button("Not rated") { editTasks { $0.hardness = nil } }
                    }
                    Menu("Move") {
                        Button("1 day earlier") { move(-1) }
                        Button("1 day later") { move(1) }
                        Button("1 week later") { move(7) }
                    }
                } label: { Label("Change", systemImage: "slider.horizontal.3") }
                .fixedSize()
                Menu {
                    Button("Delete only these days") { model.pushWeekUndo(); for o in picked { store.delete(o, scope: .one) }; model.weekSelection = [:] }
                    Button("Delete these and later repeats") { model.pushWeekUndo(); for o in picked { store.delete(o, scope: .fromHere) }; model.weekSelection = [:] }
                    Divider()
                    Button("Delete the whole tasks…", role: .destructive) { confirmDeleteAll = true }
                } label: { Label("Delete", systemImage: "trash") }
                .fixedSize()
            }
            Spacer()
            if !picked.isEmpty { Button("Clear") { model.weekSelection = [:] } }
            Button("Done") { model.weekSelection = [:]; model.weekSelecting = false }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10))
        .confirmationDialog("Delete \(taskIDs.count) task\(taskIDs.count == 1 ? "" : "s") completely, every repeat included?", isPresented: $confirmDeleteAll) {
            Button("Delete", role: .destructive) { model.pushWeekUndo(); for id in taskIDs { store.delete(taskID: id) }; model.weekSelection = [:] }
        }
        .sheet(isPresented: $checkingOff) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Check off \(picked.count) item\(picked.count == 1 ? "" : "s")").font(.app(.headline))
                Text("One reflection, saved for each of them.").font(.app(.caption)).foregroundStyle(.secondary)
                TextEditor(text: $reflection).frame(height: 90).border(.separator)
                let need = store.settings.minReflectionWords, have = countWords(reflection)
                HStack {
                    if have < need { Text("\(need - have) more word\(need - have == 1 ? "" : "s")").font(.app(.caption)).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Cancel") { checkingOff = false }
                    Button("Check off") {
                        for o in picked where !o.isResolved { store.complete(o, reflection: reflection) }
                        reflection = ""; checkingOff = false; model.weekSelection = [:]
                    }.keyboardShortcut(.defaultAction).disabled(have < need)
                }
            }
            .padding(20).frame(width: 380)
        }
    }

    private func pickDay(_ d: Date) {
        for o in google.visibleOccurrences(on: d) where !o.isResolved && !o.task.isEvent && (!o.isUntilDone || o.isUntilDoneWeekDay) {
            model.weekSelection[o.id] = o
        }
    }
    private func editTasks(_ change: (inout PlanTask) -> Void) {
        model.pushWeekUndo()
        for id in taskIDs { if var t = store.task(id) { change(&t); store.upsert(t) } }
        model.weekSelection = [:]
    }
    /// Moves one-off tasks by whole days (repeating ones keep their pattern, so they're left alone).
    private func move(_ days: Int) {
        model.pushWeekUndo()
        for id in taskIDs { if var t = store.task(id), !t.recurrence.isRepeating { t.startDate = t.startDate.adding(days: days); t.dueDate = t.dueDate?.adding(days: days); store.upsert(t) } }
        model.weekSelection = [:]
    }
}

/// Where each task sits on the week calendar, for shift-drag picking.
struct WeekFrame: Equatable { var rect: CGRect; var occ: Occurrence; static func == (a: Self, b: Self) -> Bool { a.rect == b.rect && a.occ.id == b.occ.id } }
struct WeekFramesKey: PreferenceKey {
    static var defaultValue: [String: WeekFrame] = [:]
    static func reduce(value: inout [String: WeekFrame], nextValue: () -> [String: WeekFrame]) { value.merge(nextValue()) { $1 } }
}
extension View {
    @ViewBuilder func reportWeekFrame(_ item: CalendarItem) -> some View {
        if case .task(let o) = item {
            background(GeometryReader { g in Color.clear.preference(key: WeekFramesKey.self, value: [o.id: WeekFrame(rect: g.frame(in: .named("week")), occ: o)]) })
        } else { self }
    }
}

/// Shift + drag on the week calendar: draw a box, and every task it touches is picked.
struct WeekBandPicker: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @State private var band: CGRect?
    @State private var frames: [String: WeekFrame] = [:]
    func body(content: Content) -> some View {
        content
            .coordinateSpace(name: "week")
            .onPreferenceChange(WeekFramesKey.self) { frames = $0 }
            .overlay(alignment: .topLeading) {
            if let r = band {
                Rectangle().fill(Color.accentColor.opacity(0.12)).overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1))
                    .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY).allowsHitTesting(false)
            }
        }
        // Shift + drag: draw a box, and every task it touches is picked.
            .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("week"))
            .onChanged { v in
                guard band != nil || NSEvent.modifierFlags.contains(.shift) else { return }
                band = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                              width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
            }
            .onEnded { _ in
                guard let r = band else { return }
                for (id, f) in frames where f.rect.intersects(r) && !f.occ.isResolved { model.weekSelection[id] = f.occ }
                band = nil
            })
    }
}

/// ⌘Z / ⌘X / ⌘C / ⌘V on the week calendar (see WeekClipboard.swift).
struct WeekKeys: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @State private var monitor: Any?
    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] e in
                    MainActor.assumeIsolated { (model?.weekKey(e) ?? false) ? nil : e }
                }
            }
            .onDisappear { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil }
    }
}

extension AppModel {
    func weekHover(_ item: CalendarItem, _ inside: Bool) {
        guard case .task(let o) = item else { return }
        if inside { weekHoverOcc = o } else if weekHoverOcc?.id == o.id { weekHoverOcc = nil }
    }
}
