import SwiftUI

/// Projects: big goals broken into subtasks (and subtasks of subtasks), each with its own deadline,
/// plus a timeline and a map to see the whole thing at once.
struct ProjectsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store

    var body: some View {
        if let id = model.openProjectID, store.project(id) != nil {
            ProjectDetail(id: id)
        } else {
            ProjectList()
        }
    }
}

// MARK: - All projects

private struct ProjectList: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    @State private var showArchived = false
    @AppStorage("projectListGantt") private var gantt = false
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        let active = store.activeProjects
        let archived = store.projects.filter { $0.archived == true }
        VStack(spacing: 0) {
            ScreenHeader(title: "Projects", subtitle: "Break a big goal into subtasks, give each a deadline, and see it all on a Gantt chart.") {
                Picker("View", selection: $gantt) {
                    Label("Cards", systemImage: "square.grid.2x2").tag(false)
                    Label("Gantt", systemImage: "chart.bar.xaxis").tag(true)
                }
                .pickerStyle(.segmented).fixedSize()
                Button { newProject() } label: { Label("New Project", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if gantt && !active.isEmpty {
                        HStack {
                            Text("Every project on one chart. Click a project's name to fold it; click a subtask to open its project.")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Fold all") { collapsed = Set(active.map(\.id)) }.controlSize(.small)
                            Button("Unfold all") { collapsed = [] }.controlSize(.small)
                        }
                        Card {
                            GanttChart(projects: active, collapsed: collapsed, onSelect: { id in
                                if let p = active.first(where: { $0.item(id) != nil }) { model.openProjectID = p.id }
                            }, onToggleProject: { id in
                                if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
                            })
                        }
                    } else if active.isEmpty {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("No projects yet", systemImage: "square.stack.3d.up").font(.headline)
                                Text("A project is anything with several steps: an essay, a science fair entry, a trip. Add subtasks, split those into smaller ones, and give any of them a deadline. Deadlines coming up show on your Today list.")
                                    .foregroundStyle(.secondary)
                                Button { newProject() } label: { Label("Start a project", systemImage: "plus") }
                                    .buttonStyle(.borderedProminent).padding(.top, 4)
                            }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                            ForEach(active) { p in ProjectCard(project: p) }
                        }
                    }
                    if !archived.isEmpty {
                        DisclosureGroup(isExpanded: $showArchived) {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                                ForEach(archived) { p in ProjectCard(project: p) }
                            }
                            .padding(.top, 8)
                        } label: {
                            Text("Archived (\(archived.count))").font(.headline)
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: 1100, alignment: .leading)
            }
        }
    }

    private func newProject() {
        let p = Project(title: "", color: TaskColor.allCases.filter { $0 != .gray }.randomElement() ?? .purple)
        store.upsert(p)
        model.openProjectID = p.id
    }
}

private struct ProjectCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    let project: Project

    var body: some View {
        let p = project.progress
        let rows = project.rows()
        let overdue = rows.filter { !$0.item.isDone && $0.item.due.map { $0 < DateKey.string(Date()) } == true }.count
        let next = rows.filter { !$0.item.isDone && $0.item.due != nil }.min { $0.item.due! < $1.item.due! }
        Button { model.openProjectID = project.id } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 2).fill(project.color.color).frame(width: 4, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.title.isEmpty ? "Untitled project" : project.title).font(.headline).lineLimit(1)
                        Text(p.total == 0 ? "No subtasks yet" : "\(p.done) of \(p.total) done").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if p.total > 0 { ProgressRing(done: p.done, total: p.total, size: 34, lineWidth: 4) }
                }
                ProgressView(value: Double(p.done), total: Double(max(1, p.total))).tint(project.color.color)
                HStack(spacing: 6) {
                    if let d = project.due { DueChip(due: d, done: project.isDone) }
                    if overdue > 0 {
                        Label("\(overdue) overdue", systemImage: "exclamationmark.circle.fill").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                    }
                    Spacer()
                }
                if let n = next {
                    HStack(spacing: 4) {
                        Text("Next:").foregroundStyle(.secondary)
                        Text(n.item.title.isEmpty ? "Untitled" : n.item.title).lineLimit(1)
                        Spacer()
                        DueChip(due: n.item.due!, compact: true)
                    }
                    .font(.caption)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(project.archived == true ? "Unarchive" : "Archive") { store.editProject(project.id) { $0.archived = $0.archived == true ? nil : true } }
            Button("Delete", role: .destructive) { store.deleteProject(project.id) }
        }
    }
}

// MARK: - One project

enum ProjectViewMode: String, CaseIterable, Identifiable {
    case outline = "Outline", gantt = "Gantt", map = "Map"
    var id: String { rawValue }
    var symbol: String { self == .outline ? "list.bullet.indent" : self == .gantt ? "chart.bar.xaxis" : "point.3.connected.trianglepath.dotted" }
}

private struct ProjectDetail: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    let id: UUID
    @AppStorage("projectViewMode") private var mode: ProjectViewMode = .outline
    @State private var collapsed: Set<UUID> = []
    @State private var selected: UUID?
    @State private var newTitle = ""
    @State private var confirmDelete = false
    @FocusState private var focusedItem: UUID?

    private var project: Project { store.project(id) ?? Project(title: "") }
    private func edit(_ change: (inout Project) -> Void) { store.editProject(id, change) }

    var body: some View {
        let p = project
        let prog = p.progress
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { model.openProjectID = nil } label: { Label("Projects", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
                Picker("View", selection: $mode) {
                    ForEach(ProjectViewMode.allCases) { m in Label(m.rawValue, systemImage: m.symbol).tag(m) }
                }
                .pickerStyle(.segmented).fixedSize()
                Menu {
                    Button(p.archived == true ? "Unarchive" : "Archive") { edit { $0.archived = $0.archived == true ? nil : true } }
                    Button("Expand all") { collapsed = [] }
                    Button("Collapse all") { collapsed = Set(p.rows().filter { !$0.item.items.isEmpty }.map(\.id)) }
                    Divider()
                    Button("Delete project…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(.horizontal, 22).padding(.top, 12)

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Project name", text: Binding(get: { project.title }, set: { v in edit { $0.title = v } }))
                        .textFieldStyle(.plain).font(.largeTitle.bold())
                    HStack(spacing: 10) {
                        Menu {
                            ForEach(TaskColor.allCases) { c in
                                Button { edit { $0.color = c } } label: { Label(c.rawValue.capitalized, systemImage: "circle.fill") }
                            }
                        } label: { Circle().fill(p.color.color).frame(width: 14, height: 14) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Colour")
                        DayButton(title: "Start", symbol: "play.fill", key: Binding(get: { project.start }, set: { v in edit { $0.start = v } }),
                                  placeholder: "Started \(shortDay(p.startKey))")
                        DayButton(title: "Deadline", symbol: "flag.fill", key: Binding(get: { project.due }, set: { v in edit { $0.due = v } }),
                                  status: DeadlineStatus.of(due: p.due, done: p.isDone))
                        Text(prog.total == 0 ? "Add subtasks below" : "\(prog.done) of \(prog.total) done")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ProgressRing(done: prog.done, total: prog.total, size: 64, lineWidth: 8)
            }
            .padding(.horizontal, 22).padding(.vertical, 12)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch mode {
                    case .outline: outline(p)
                    case .gantt:
                        legend
                        Card { GanttChart(projects: [p], collapsed: collapsed, selected: selected) { sid in selected = sid } }
                        selectedEditor(p)
                    case .map:
                        legend
                        Card { ProjectMap(project: p, collapsed: collapsed, selected: selected) { sid in selected = sid } }
                        selectedEditor(p)
                    }
                }
                .padding(22)
                .frame(maxWidth: 1200, alignment: .leading)
            }
        }
        .confirmationDialog("Delete “\(p.title.isEmpty ? "Untitled project" : p.title)” and all its subtasks?", isPresented: $confirmDelete) {
            Button("Delete project", role: .destructive) { model.openProjectID = nil; store.deleteProject(id) }
        }
        .onChange(of: id) { _, _ in collapsed = []; selected = nil }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach([(Color.red, "Overdue"), (.orange, "Due today"), (.green, "Done"), (project.color.color, "On track")], id: \.1) { c, t in
                HStack(spacing: 4) { RoundedRectangle(cornerRadius: 3).fill(c.opacity(0.6)).frame(width: 14, height: 8); Text(t) }
            }
            HStack(spacing: 4) { Image(systemName: "diamond.fill").font(.system(size: 8)); Text("Deadline") }
            HStack(spacing: 4) { Rectangle().fill(Color.red).frame(width: 2, height: 10); Text("Today") }
            Spacer()
            Text("Click a row to edit it. Collapse subtasks in the outline to simplify the picture.").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    /// Under the timeline and map: edit whatever row was clicked.
    @ViewBuilder private func selectedEditor(_ p: Project) -> some View {
        if let sid = selected, let row = p.rows(collapsed: collapsed).first(where: { $0.id == sid }) {
            Card {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected").font(.caption).foregroundStyle(.secondary)
                    ItemRow(projectID: id, row: row, collapsed: $collapsed, focused: $focusedItem, showPath: true)
                }
            }
        }
    }

    // MARK: Outline

    @ViewBuilder private func outline(_ p: Project) -> some View {
        let rows = p.rows(collapsed: collapsed)
        Card {
            VStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty {
                    Text("No subtasks yet. Add the first one below, then use the + on a row to break it down further.")
                        .foregroundStyle(.secondary).padding(.vertical, 6)
                }
                ForEach(rows) { r in
                    ItemRow(projectID: id, row: r, collapsed: $collapsed, focused: $focusedItem)
                }
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(p.color.color)
                    TextField("Add a subtask — press Return", text: $newTitle)
                        .textFieldStyle(.plain)
                        .onSubmit(addTop)
                }
                .padding(.vertical, 8).padding(.leading, 4)
            }
        }
        Text("Tip: hover a row for its buttons. Use + to add a subtask inside it, and the arrows to move it in or out a level. A subtask with subtasks is done when they all are.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func addTop() {
        let t = newTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        edit { $0.insert(ProjectItem(title: t), under: nil) }
        newTitle = ""
    }
}

/// One outline row: collapse arrow, check circle, editable title, deadline, and (on hover) the row's buttons.
private struct ItemRow: View {
    @EnvironmentObject private var store: Store
    let projectID: UUID
    let row: Project.Row
    @Binding var collapsed: Set<UUID>
    var focused: FocusState<UUID?>.Binding
    var showPath = false
    @State private var hovering = false

    private func edit(_ change: (inout Project) -> Void) { store.editProject(projectID, change) }
    private var item: ProjectItem { row.item }

    var body: some View {
        let hasKids = !item.items.isEmpty
        let p = item.progress
        HStack(spacing: 6) {
            Button {
                if collapsed.contains(item.id) { collapsed.remove(item.id) } else { collapsed.insert(item.id) }
            } label: {
                Image(systemName: collapsed.contains(item.id) ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .bold)).frame(width: 12)
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).opacity(hasKids ? 1 : 0).disabled(!hasKids)

            Button { edit { p in p.update(item.id) { $0.setDone(!item.isDone) } } } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : hasKids ? "circle.dashed" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(item.isDone ? Color.green : .secondary)
            }
            .buttonStyle(.plain)
            .help(hasKids ? (item.isDone ? "Mark everything inside not done" : "Mark everything inside done") : item.isDone ? "Mark not done" : "Mark done")

            TextField("Subtask", text: Binding(get: { item.title }, set: { v in edit { p in p.update(item.id) { $0.title = v } } }))
                .textFieldStyle(.plain)
                .font(row.depth == 0 ? .body.weight(.medium) : .body)
                .strikethrough(item.isDone && !hasKids)
                .foregroundStyle(item.isDone ? .secondary : .primary)
                .focused(focused, equals: item.id)
                .onSubmit { addSibling() }

            if hasKids {
                Text("\(p.done)/\(p.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                ProgressView(value: Double(p.done), total: Double(p.total)).frame(width: 50).controlSize(.small)
            }
            if item.isUrgent || hovering {
                Button { edit { p in p.update(item.id) { $0.urgent = item.isUrgent ? nil : true } } } label: {
                    Label("Urgent", systemImage: item.isUrgent ? "exclamationmark.circle.fill" : "exclamationmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(item.isUrgent ? Color.red : .secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill((item.isUrgent ? Color.red : .secondary).opacity(item.isUrgent ? 0.14 : 0.08)))
                }
                .buttonStyle(.plain)
                .help(item.isUrgent ? "Urgent: on today's list and in today's progress ring. Click to unmark." : "Mark urgent: put it on today's list and in today's progress ring")
            }
            if row.conflict {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                    .help("This deadline is after \(row.limit.map(shortDay) ?? "")—the deadline of what it's part of.")
            }
            if hovering || item.start != nil {
                DayButton(title: "Start", symbol: "play.fill",
                          key: Binding(get: { item.start }, set: { v in edit { p in p.update(item.id) { $0.start = v } } }), compact: true)
            }
            if let due = item.due {
                DayButton(title: "Deadline", symbol: "flag.fill",
                          key: Binding(get: { item.due }, set: { v in edit { p in p.update(item.id) { $0.due = v } } }),
                          status: DeadlineStatus.of(due: due, done: item.isDone), compact: true)
            } else if hovering {
                DayButton(title: "Deadline", symbol: "flag",
                          key: Binding(get: { item.due }, set: { v in edit { p in p.update(item.id) { $0.due = v } } }), compact: true)
            } else if let inherited = row.due {
                DueChip(due: inherited, done: item.isDone, inherited: true, compact: true)
            }
            HStack(spacing: 2) {
                Button { addChild() } label: { Image(systemName: "plus") }.help("Add a subtask inside this one")
                Button { edit { $0.outdent(item.id) } } label: { Image(systemName: "arrow.left") }.help("Move out a level").disabled(row.parentID == nil)
                Button { edit { $0.indent(item.id) } } label: { Image(systemName: "arrow.right") }.help("Make it a subtask of the one above")
                Menu {
                    Button("Move up") { edit { $0.move(item.id, by: -1) } }
                    Button("Move down") { edit { $0.move(item.id, by: 1) } }
                    Divider()
                    Button("Delete", role: .destructive) { edit { $0.remove(item.id) } }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .buttonStyle(.borderless)
            .opacity(hovering ? 1 : 0)
        }
        .padding(.leading, CGFloat(row.depth) * 22)
        .padding(.vertical, 4).padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.04) : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Add subtask inside") { addChild() }
            Button("Add subtask below") { addSibling() }
            Button(item.isUrgent ? "Not urgent" : "Mark urgent (on today's list)") { edit { p in p.update(item.id) { $0.urgent = item.isUrgent ? nil : true } } }
            Button("Move in a level") { edit { $0.indent(item.id) } }
            Button("Move out a level") { edit { $0.outdent(item.id) } }.disabled(row.parentID == nil)
            Divider()
            Button("Delete", role: .destructive) { edit { $0.remove(item.id) } }
        }
    }

    private func addChild() {
        let n = ProjectItem(title: "")
        edit { $0.insert(n, under: item.id) }
        collapsed.remove(item.id)
        DispatchQueue.main.async { focused.wrappedValue = n.id }
    }

    private func addSibling() {
        let n = ProjectItem(title: "")
        edit { $0.insert(n, under: row.parentID, after: item.id) }
        DispatchQueue.main.async { focused.wrappedValue = n.id }
    }
}

/// A date that may be unset: shows the day (coloured by status) or "Deadline", and opens a calendar.
struct DayButton: View {
    let title: String
    let symbol: String
    @Binding var key: String?
    var placeholder: String?
    var status: DeadlineStatus = .none
    var compact = false
    @State private var open = false
    @State private var picked = Date()

    var body: some View {
        Button { picked = key.flatMap(DateKey.date) ?? Date(); open = true } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9))
                if let k = key {
                    Text(compact ? shortDay(k) : "\(title): \(shortDay(k))\(title == "Deadline" ? " · \(dueRelative(k))" : "")")
                } else {
                    Text(placeholder ?? title)
                }
            }
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(key == nil ? Color.secondary : status == .later || status == .none ? Color.primary : status.color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill((key == nil || status == .later || status == .none ? Color.secondary : status.color).opacity(key == nil ? 0.08 : 0.15)))
        }
        .buttonStyle(.plain)
        .help(key == nil ? "Set a \(title.lowercased())" : "Change the \(title.lowercased())")
        .popover(isPresented: $open) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                DatePicker(title, selection: $picked, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                HStack {
                    if key != nil { Button("Remove", role: .destructive) { key = nil; open = false } }
                    Spacer()
                    Button("Cancel") { open = false }
                    Button("Set") { key = DateKey.string(picked); open = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(14).frame(width: 260)
        }
    }
}

/// How far ahead project subtasks join today's list (and its progress ring).
let projectTodayChoices: [(Int, String)] = [(-1, "Only urgent ones"), (0, "Due today"), (1, "Due by tomorrow"), (2, "Due within 2 days"), (3, "Due within 3 days"), (7, "Due within a week")]

/// On the Today screen: project subtasks that are on today's list (urgent, or due within the setting's
/// window). They count in today's progress ring. Checking one off needs no reflection.
struct ProjectTodaySection: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store

    var body: some View {
        let list = store.projectToday()
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    SectionTitle(text: "Project tasks", symbol: "square.stack.3d.up", count: list.filter { $0.item?.isDone == false }.count)
                    Spacer()
                    ProjectTodayMenu()
                }
                Card { VStack(spacing: 0) { ForEach(Array(list.enumerated()), id: \.element.id) { i, d in
                    if i > 0 { Divider().padding(.leading, 30) }
                    ProjectDeadlineRow(d: d)
                } } }
            }
        }
    }
}

/// On the Today screen: project deadlines coming up this week that aren't on today's list. Not counted.
struct ProjectUpcomingSection: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        let list = store.projectUpcoming()
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle(text: "Coming up in projects", symbol: "flag", count: list.count)
                    Text("not counted in today's progress").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if store.projectToday().isEmpty { ProjectTodayMenu() }
                }
                Card { VStack(spacing: 0) { ForEach(Array(list.enumerated()), id: \.element.id) { i, d in
                    if i > 0 { Divider().padding(.leading, 30) }
                    ProjectDeadlineRow(d: d, upcoming: true)
                } } }
            }
        }
    }
}

/// "Counts today: Due today ▾" with the urgent tip.
struct ProjectTodayMenu: View {
    @EnvironmentObject private var store: Store
    var body: some View {
        Menu {
            Picker("Project tasks on today's list", selection: $store.settings.projectTodayDays) {
                ForEach(projectTodayChoices, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.inline)
            Divider()
            Text("Urgent subtasks are always on today's list.")
        } label: {
            Text("On today: \(projectTodayChoices.first { $0.0 == store.settings.projectTodayDays }?.1.lowercased() ?? "due today")")
        }
        .menuStyle(.borderlessButton).fixedSize().font(.caption)
        .help("Which project subtasks join today's list and its progress ring")
    }
}

private struct ProjectDeadlineRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store
    let d: ProjectDeadline
    var upcoming = false

    var body: some View {
        let done = d.item?.isDone == true
        HStack(spacing: 10) {
            if let item = d.item {
                Button { store.toggleProjectItem(d) } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : item.items.isEmpty ? "circle" : "circle.dashed").font(.system(size: 17))
                        .foregroundStyle(done ? d.project.color.color : .secondary)
                }
                .buttonStyle(.plain).help(done ? "Mark not done" : item.items.isEmpty ? "Mark done" : "Mark it and everything inside done")
            } else {
                Image(systemName: "flag.checkered").font(.system(size: 15)).foregroundStyle(d.project.color.color).frame(width: 17)
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(d.item == nil ? "\(d.title.isEmpty ? "Untitled project" : d.title) (whole project)" : d.title.isEmpty ? "Untitled" : d.title)
                        .strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                    if d.item?.isUrgent == true && !done {
                        Text("URGENT").font(.system(size: 9, weight: .heavy)).foregroundStyle(.red)
                            .padding(.horizontal, 4).padding(.vertical, 1).background(Capsule().fill(Color.red.opacity(0.14)))
                    }
                }
                Text(([d.project.title.isEmpty ? "Untitled project" : d.project.title] + d.path).joined(separator: " › "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let due = d.due { DueChip(due: due, done: done) }
            if upcoming, let item = d.item {
                Button { store.editProject(d.project.id) { p in p.update(item.id) { $0.urgent = true } } } label: {
                    Image(systemName: "exclamationmark.circle")
                }
                .buttonStyle(.borderless).help("Mark urgent: move it onto today's list")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.openProjectID = d.project.id; model.screen = .projects }
    }
}
