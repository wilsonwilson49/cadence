import SwiftUI

// Projects on iPhone: the list (or every project on one Gantt chart), and each project as an outline,
// a Gantt chart or a map. Shares the model and the visuals with the Mac app.

struct ProjectsScreen: View {
    @EnvironmentObject private var store: Store
    @AppStorage("projectListGantt") private var gantt = false
    @State private var open: UUID?
    @State private var collapsed: Set<UUID> = []

    var body: some View {
        let active = store.activeProjects
        let archived = store.projects.filter { $0.archived == true }
        List {
            Section {
                Picker("View", selection: $gantt) { Text("List").tag(false); Text("Gantt").tag(true) }.pickerStyle(.segmented)
            }
            if active.isEmpty {
                Section {
                    Text("A project is anything with several steps: an essay, a science fair entry, a trip. Add subtasks, split those into smaller ones, and give any of them a deadline.")
                        .foregroundStyle(.secondary)
                    Button { newProject() } label: { Label("Start a project", systemImage: "plus") }
                }
            } else if gantt {
                Section {
                    GanttChart(projects: active, collapsed: collapsed, labelWidth: 150, rowHeight: 32, onSelect: { id in
                        open = active.first { $0.item(id) != nil }?.id
                    }, onToggleProject: { id in
                        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
                    })
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 0))
                } footer: { Text("Tap a project's name to fold it, a subtask to open its project. Scroll the chart sideways.") }
            } else {
                Section { ForEach(active) { p in row(p) } }
            }
            if !archived.isEmpty && !gantt {
                Section("Archived") { ForEach(archived) { p in row(p) } }
            }
        }
        .navigationTitle("Projects")
        .toolbar { Button { newProject() } label: { Image(systemName: "plus") } }
        .navigationDestination(item: $open) { id in ProjectScreen(id: id) }
    }

    private func row(_ p: Project) -> some View {
        let pr = p.progress
        return Button { open = p.id } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    RoundedRectangle(cornerRadius: 2).fill(p.color.color).frame(width: 4, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.title.isEmpty ? "Untitled project" : p.title).font(.headline).foregroundStyle(.primary)
                        Text(pr.total == 0 ? "No subtasks yet" : "\(pr.done) of \(pr.total) done").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let d = p.due { DueChip(due: d, done: p.isDone) }
                }
                ProgressView(value: Double(pr.done), total: Double(max(1, pr.total))).tint(p.color.color)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) { store.deleteProject(p.id) } label: { Label("Delete", systemImage: "trash") }
            Button { store.editProject(p.id) { $0.archived = $0.archived == true ? nil : true } } label: {
                Label(p.archived == true ? "Unarchive" : "Archive", systemImage: "archivebox")
            }
        }
    }

    private func newProject() {
        let p = Project(title: "", color: TaskColor.allCases.filter { $0 != .gray }.randomElement() ?? .purple)
        store.upsert(p)
        open = p.id
    }
}

struct ProjectScreen: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @AppStorage("projectViewMode") private var mode = "Outline"
    @State private var collapsed: Set<UUID> = []
    @State private var selected: UUID?
    @State private var newTitle = ""
    @State private var dateEdit: DateEdit?
    @State private var confirmDelete = false
    @FocusState private var focused: UUID?

    struct DateEdit: Identifiable {
        var item: UUID?      // nil = the project itself
        var field: String    // "start" or "due"
        var id: String { "\(item?.uuidString ?? "p")\(field)" }
    }

    private var project: Project { store.project(id) ?? Project(title: "") }
    private func edit(_ change: (inout Project) -> Void) { store.editProject(id, change) }

    var body: some View {
        let p = project, pr = p.progress
        List {
            Section {
                TextField("Project name", text: Binding(get: { project.title }, set: { v in edit { $0.title = v } }), axis: .vertical)
                    .font(.title2.bold())
                HStack(spacing: 8) {
                    Menu {
                        ForEach(TaskColor.allCases) { c in Button(c.rawValue.capitalized) { edit { $0.color = c } } }
                    } label: { Circle().fill(p.color.color).frame(width: 18, height: 18) }
                    chip(p.start.map { "Start \(shortDay($0))" } ?? "Start", symbol: "play.fill", set: p.start != nil) { dateEdit = DateEdit(item: nil, field: "start") }
                    chip(p.due.map { "Due \(shortDay($0))" } ?? "Deadline", symbol: "flag.fill", set: p.due != nil,
                         status: DeadlineStatus.of(due: p.due, done: p.isDone)) { dateEdit = DateEdit(item: nil, field: "due") }
                    Spacer()
                    Text(pr.total == 0 ? "" : "\(pr.done)/\(pr.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                if pr.total > 0 { ProgressView(value: Double(pr.done), total: Double(pr.total)).tint(p.color.color) }
                Picker("View", selection: $mode) { ForEach(["Outline", "Gantt", "Map"], id: \.self) { Text($0).tag($0) } }
                    .pickerStyle(.segmented)
            }
            switch mode {
            case "Gantt":
                Section {
                    GanttChart(projects: [p], collapsed: collapsed, labelWidth: 150, rowHeight: 32, selected: selected,
                               onSelect: { selected = $0 }, onToggleProject: { _ in })
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 0))
                } footer: { Text("Scroll the chart sideways. Tap a row to edit it below.") }
                selectedSection(p)
            case "Map":
                Section {
                    ProjectMap(project: p, collapsed: collapsed, nodeWidth: 160, selected: selected) { selected = $0 }
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                } footer: { Text("Scroll sideways to follow the branches. Tap a box to edit it below.") }
                selectedSection(p)
            default:
                Section {
                    ForEach(p.rows(collapsed: collapsed)) { r in itemRow(r) }
                    HStack {
                        Image(systemName: "plus.circle.fill").foregroundStyle(p.color.color)
                        TextField("Add a subtask", text: $newTitle).submitLabel(.done).onSubmit(addTop)
                    }
                } footer: {
                    Text("Touch and hold a row to add a subtask inside it, move it in or out a level, or mark it urgent. A subtask with subtasks is done when they all are.")
                }
            }
            Section {
                Button(p.archived == true ? "Unarchive project" : "Archive project") { edit { $0.archived = $0.archived == true ? nil : true } }
                Button("Delete project", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(p.title.isEmpty ? "Project" : p.title)
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $dateEdit) { e in dateSheet(e) }
        .confirmationDialog("Delete this project and all its subtasks?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete project", role: .destructive) { store.deleteProject(id); dismiss() }
        }
    }

    @ViewBuilder private func selectedSection(_ p: Project) -> some View {
        if let sid = selected, let r = p.rows(collapsed: collapsed).first(where: { $0.id == sid }) {
            Section("Selected") { itemRow(r, flat: true) }
        }
    }

    private func chip(_ text: String, symbol: String, set: Bool, status: DeadlineStatus = .none, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) { Image(systemName: symbol).font(.system(size: 9)); Text(text) }.font(.caption.weight(.semibold)).fixedSize()
                .foregroundStyle(!set ? Color.secondary : status == .later || status == .none ? Color.primary : status.color)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill((!set || status == .later || status == .none ? Color.secondary : status.color).opacity(set ? 0.15 : 0.1)))
        }
    }

    private func itemRow(_ r: Project.Row, flat: Bool = false) -> some View {
        let i = r.item, kids = !i.items.isEmpty, pr = i.progress
        return HStack(spacing: 8) {
            if kids && !flat {
                Button { if collapsed.contains(i.id) { collapsed.remove(i.id) } else { collapsed.insert(i.id) } } label: {
                    Image(systemName: collapsed.contains(i.id) ? "chevron.right" : "chevron.down").font(.caption2.weight(.bold)).frame(width: 12)
                }
                .foregroundStyle(.secondary)
            } else if !flat { Color.clear.frame(width: 12) }
            Button { edit { p in p.update(i.id) { $0.setDone(!i.isDone) } } } label: {
                Image(systemName: i.isDone ? "checkmark.circle.fill" : kids ? "circle.dashed" : "circle").font(.title3)
                    .foregroundStyle(i.isDone ? Color.green : .secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                TextField("Subtask", text: Binding(get: { i.title }, set: { v in edit { p in p.update(i.id) { $0.title = v } } }), axis: .vertical)
                    .font(r.depth == 0 ? .body.weight(.medium) : .body)
                    .foregroundStyle(i.isDone ? .secondary : .primary)
                    .focused($focused, equals: i.id)
                HStack(spacing: 6) {
                    if i.isUrgent && !i.isDone {
                        Text("URGENT").font(.system(size: 9, weight: .heavy)).foregroundStyle(.red)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Color.red.opacity(0.14)))
                    }
                    if let d = i.due {
                        Button { dateEdit = DateEdit(item: i.id, field: "due") } label: { DueChip(due: d, done: i.isDone) }
                    } else if let d = r.due {
                        Button { dateEdit = DateEdit(item: i.id, field: "due") } label: { DueChip(due: d, done: i.isDone, inherited: true, compact: true) }
                    }
                    if r.conflict { Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.red) }
                    if kids { Text("\(pr.done)/\(pr.total)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                }
                .buttonStyle(.borderless)
            }
        }
        .buttonStyle(.borderless)
        .padding(.leading, flat ? 0 : CGFloat(r.depth) * 18)
        .contextMenu {
            Button { addChild(i.id) } label: { Label("Add subtask inside", systemImage: "plus") }
            Button { addSibling(after: i.id, parent: r.parentID) } label: { Label("Add subtask below", systemImage: "text.insert") }
            Button { edit { p in p.update(i.id) { $0.urgent = i.isUrgent ? nil : true } } } label: {
                Label(i.isUrgent ? "Not urgent" : "Mark urgent (on today's list)", systemImage: "exclamationmark.circle")
            }
            Button { dateEdit = DateEdit(item: i.id, field: "due") } label: { Label(i.due == nil ? "Set deadline" : "Change deadline", systemImage: "flag") }
            Button { dateEdit = DateEdit(item: i.id, field: "start") } label: { Label(i.start == nil ? "Set start" : "Change start", systemImage: "play") }
            Button { edit { $0.indent(i.id) } } label: { Label("Move in a level", systemImage: "arrow.right") }
            if r.parentID != nil { Button { edit { $0.outdent(i.id) } } label: { Label("Move out a level", systemImage: "arrow.left") } }
            Button { edit { $0.move(i.id, by: -1) } } label: { Label("Move up", systemImage: "arrow.up") }
            Button { edit { $0.move(i.id, by: 1) } } label: { Label("Move down", systemImage: "arrow.down") }
            Button(role: .destructive) { edit { $0.remove(i.id) } } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { edit { $0.remove(i.id) } } label: { Label("Delete", systemImage: "trash") }
            Button { edit { p in p.update(i.id) { $0.urgent = i.isUrgent ? nil : true } } } label: { Label("Urgent", systemImage: "exclamationmark.circle") }.tint(.red)
        }
        .swipeActions(edge: .leading) {
            Button { addChild(i.id) } label: { Label("Subtask", systemImage: "plus") }.tint(.blue)
        }
    }

    private func dateSheet(_ e: DateEdit) -> some View {
        let current: String? = {
            if let item = e.item { let i = project.item(item); return e.field == "due" ? i?.due : i?.start }
            return e.field == "due" ? project.due : project.start
        }()
        return ProjectDateSheet(title: e.field == "due" ? "Deadline" : "Start", initial: current.flatMap(DateKey.date) ?? Date(), hasValue: current != nil) { key in
            edit { p in
                if let item = e.item {
                    p.update(item) { if e.field == "due" { $0.due = key } else { $0.start = key } }
                } else if e.field == "due" { p.due = key } else { p.start = key }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func addTop() {
        let t = newTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        edit { $0.insert(ProjectItem(title: t), under: nil) }
        newTitle = ""
    }
    private func addChild(_ parent: UUID) {
        let n = ProjectItem(title: "")
        edit { $0.insert(n, under: parent) }
        collapsed.remove(parent)
        if mode != "Outline" { mode = "Outline" }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = n.id }
    }
    private func addSibling(after id: UUID, parent: UUID?) {
        let n = ProjectItem(title: "")
        edit { $0.insert(n, under: parent, after: id) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = n.id }
    }
}

private struct ProjectDateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @State var initial: Date
    let hasValue: Bool
    let save: (String?) -> Void

    var body: some View {
        NavigationStack {
            DatePicker(title, selection: $initial, displayedComponents: .date).datePickerStyle(.graphical).padding()
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Set") { save(DateKey.string(initial)); dismiss() } }
                    if hasValue {
                        ToolbarItem(placement: .bottomBar) { Button("Remove \(title.lowercased())", role: .destructive) { save(nil); dismiss() } }
                    }
                }
        }
    }
}

/// On Today: project subtasks on today's list (counted in the ring), and ones coming up (not counted).
struct MobileProjectSections: View {
    @EnvironmentObject private var store: Store

    var body: some View {
        let today = store.projectToday(), upcoming = store.projectUpcoming()
        if !today.isEmpty {
            Section {
                ForEach(today) { row($0) }
            } header: {
                HStack {
                    Text("Project tasks")
                    Spacer()
                    windowMenu
                }
            }
        }
        if !upcoming.isEmpty {
            Section {
                ForEach(upcoming) { row($0, upcoming: true) }
            } header: {
                HStack {
                    Text("Coming up in projects")
                    Spacer()
                    if today.isEmpty { windowMenu }
                }
            } footer: { Text("Not counted in today's progress. Swipe left to mark one urgent and put it on today's list.") }
        }
    }

    private var windowMenu: some View {
        Menu {
            Picker("On today", selection: $store.settings.projectTodayDays) {
                ForEach(mobileProjectTodayChoices, id: \.0) { Text($0.1).tag($0.0) }
            }
        } label: {
            Text("On today: \(mobileProjectTodayChoices.first { $0.0 == store.settings.projectTodayDays }?.1.lowercased() ?? "due today")")
                .font(.caption).textCase(nil)
        }
    }

    private func row(_ d: ProjectDeadline, upcoming: Bool = false) -> some View {
        let done = d.item?.isDone == true
        return HStack(spacing: 10) {
            if d.item != nil {
                Button { store.toggleProjectItem(d) } label: {
                    Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.title3).foregroundStyle(done ? d.project.color.color : .secondary)
                }
                .buttonStyle(.borderless)
            } else {
                Image(systemName: "flag.checkered").foregroundStyle(d.project.color.color).frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(d.item == nil ? "\(d.title) (whole project)" : d.title.isEmpty ? "Untitled" : d.title)
                        .strikethrough(done).foregroundStyle(done ? .secondary : .primary)
                    if d.item?.isUrgent == true && !done {
                        Text("URGENT").font(.system(size: 9, weight: .heavy)).foregroundStyle(.red)
                    }
                }
                Text(([d.project.title] + d.path).joined(separator: " › ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let due = d.due { DueChip(due: due, done: done, compact: true) }
        }
        .swipeActions {
            if upcoming, let item = d.item {
                Button { store.editProject(d.project.id) { p in p.update(item.id) { $0.urgent = true } } } label: {
                    Label("Urgent", systemImage: "exclamationmark.circle")
                }
                .tint(.red)
            }
        }
    }
}

let mobileProjectTodayChoices: [(Int, String)] = [(-1, "Only urgent ones"), (0, "Due today"), (1, "Due by tomorrow"), (2, "Due within 2 days"), (3, "Due within 3 days"), (7, "Due within a week")]
