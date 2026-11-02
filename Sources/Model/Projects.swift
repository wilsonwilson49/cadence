import Foundation

// Projects: a goal broken into subtasks, which can have their own subtasks, to any depth.
// Every level can have a start date and a deadline ("yyyy-MM-dd", same as the web app).
// A subtask with its own subtasks is done when all of them are done; progress counts the
// smallest pieces (leaves). Projects sync as their own record kind, "project".

struct ProjectItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var notes = ""
    var start: String?
    var due: String?
    var doneAt: Date?
    /// Urgent: on today's list (and in today's progress ring) whatever its deadline.
    var urgent: Bool?
    var items: [ProjectItem] = []

    var isUrgent: Bool { urgent == true }

    init(title: String, start: String? = nil, due: String? = nil, items: [ProjectItem] = []) {
        self.title = title; self.start = start; self.due = due; self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        title = c.value(.title, "")
        notes = c.value(.notes, "")
        start = c.value(.start, nil as String?)
        due = c.value(.due, nil as String?)
        doneAt = c.value(.doneAt, nil as Date?)
        urgent = c.value(.urgent, nil as Bool?)
        items = c.value(.items, [])
    }

    var isDone: Bool { items.isEmpty ? doneAt != nil : items.allSatisfy(\.isDone) }
    /// Finished and total leaves under (and including) this item.
    var progress: (done: Int, total: Int) {
        if items.isEmpty { return (doneAt != nil ? 1 : 0, 1) }
        return items.reduce((0, 0)) { acc, i in let p = i.progress; return (acc.0 + p.done, acc.1 + p.total) }
    }
    /// Marks this item and everything under it done (or not done).
    mutating func setDone(_ done: Bool, at now: Date = Date()) {
        if done { if doneAt == nil { doneAt = now } } else { doneAt = nil }
        for i in items.indices { items[i].setDone(done, at: now) }
    }
    /// After a change below, a parent follows its children: done once all are done.
    mutating func settle() {
        for i in items.indices { items[i].settle() }
        if !items.isEmpty { doneAt = items.allSatisfy(\.isDone) ? (doneAt ?? items.compactMap(\.doneAt).max()) : nil }
    }
}

struct Project: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var notes = ""
    var color: TaskColor = .purple
    var start: String?
    var due: String?
    var items: [ProjectItem] = []
    var createdAt = Date()
    var updatedAt: Date?
    var archived: Bool?

    init(title: String, color: TaskColor = .purple, start: String? = nil, due: String? = nil, items: [ProjectItem] = []) {
        self.title = title; self.color = color; self.start = start; self.due = due; self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        title = c.value(.title, "")
        notes = c.value(.notes, "")
        color = c.value(.color, TaskColor.purple)
        start = c.value(.start, nil as String?)
        due = c.value(.due, nil as String?)
        items = c.value(.items, [])
        createdAt = c.value(.createdAt, Date())
        updatedAt = c.value(.updatedAt, nil as Date?)
        archived = c.value(.archived, nil as Bool?)
    }

    var progress: (done: Int, total: Int) {
        items.reduce((0, 0)) { acc, i in let p = i.progress; return (acc.0 + p.done, acc.1 + p.total) }
    }
    var isDone: Bool { !items.isEmpty && items.allSatisfy(\.isDone) }
    var startKey: String { start ?? DateKey.string(createdAt) }

    // MARK: Editing by id, anywhere in the tree

    mutating func update(_ id: UUID, _ change: (inout ProjectItem) -> Void) {
        func walk(_ list: inout [ProjectItem]) -> Bool {
            for i in list.indices {
                if list[i].id == id { change(&list[i]); return true }
                if walk(&list[i].items) { return true }
            }
            return false
        }
        _ = walk(&items)
        for i in items.indices { items[i].settle() }
    }

    /// Adds `item` under `parent` (nil = top level), after `after` if given.
    mutating func insert(_ item: ProjectItem, under parent: UUID?, after: UUID? = nil) {
        func place(_ list: inout [ProjectItem]) {
            if let after, let i = list.firstIndex(where: { $0.id == after }) { list.insert(item, at: i + 1) } else { list.append(item) }
        }
        if let parent { update(parent) { place(&$0.items) } } else { place(&items) }
        for i in items.indices { items[i].settle() }
    }

    @discardableResult mutating func remove(_ id: UUID) -> ProjectItem? {
        func walk(_ list: inout [ProjectItem]) -> ProjectItem? {
            if let i = list.firstIndex(where: { $0.id == id }) { return list.remove(at: i) }
            for i in list.indices { if let r = walk(&list[i].items) { return r } }
            return nil
        }
        let r = walk(&items)
        for i in items.indices { items[i].settle() }
        return r
    }

    func item(_ id: UUID) -> ProjectItem? { rows().first { $0.item.id == id }?.item }
    func parent(of id: UUID) -> UUID? { rows().first { $0.item.id == id }?.parentID }

    /// Moves an item up or down among its siblings.
    mutating func move(_ id: UUID, by delta: Int) {
        func walk(_ list: inout [ProjectItem]) -> Bool {
            if let i = list.firstIndex(where: { $0.id == id }) {
                let j = i + delta
                guard list.indices.contains(j) else { return true }
                list.swapAt(i, j); return true
            }
            for i in list.indices where walk(&list[i].items) { return true }
            return false
        }
        _ = walk(&items)
    }

    /// Makes an item a subtask of the sibling above it.
    mutating func indent(_ id: UUID) {
        let rs = rows(), parentID = rs.first { $0.item.id == id }?.parentID
        let siblings = parentID.flatMap { p in item(p)?.items } ?? items
        guard let i = siblings.firstIndex(where: { $0.id == id }), i > 0 else { return }
        let newParent = siblings[i - 1].id
        guard let moved = remove(id) else { return }
        insert(moved, under: newParent)
    }

    /// Moves an item out one level, just after its old parent.
    mutating func outdent(_ id: UUID) {
        guard let parentID = parent(of: id), let moved = remove(id) else { return }
        insert(moved, under: parent(of: parentID), after: parentID)
    }

    // MARK: Flattened view, with dates passed down

    struct Row: Identifiable {
        var item: ProjectItem
        var depth: Int
        var parentID: UUID?
        /// The start and deadline that apply: its own, or the nearest parent's (then the project's).
        var start: String
        var due: String?
        /// The deadline it has to fit inside (a parent's or the project's).
        var limit: String?
        var id: UUID { item.id }
        var dueIsOwn: Bool { item.due != nil }
        /// Its deadline is later than the one it sits under.
        var conflict: Bool { if let d = item.due, let l = limit { return d > l } else { return false } }
    }

    func rows(collapsed: Set<UUID> = []) -> [Row] {
        var out: [Row] = []
        func walk(_ list: [ProjectItem], depth: Int, parent: UUID?, start: String, due: String?) {
            for i in list {
                let s = i.start ?? start, d = i.due ?? due
                out.append(Row(item: i, depth: depth, parentID: parent, start: s, due: d, limit: due))
                if !collapsed.contains(i.id) { walk(i.items, depth: depth + 1, parent: i.id, start: s, due: d) }
            }
        }
        walk(items, depth: 0, parent: nil, start: startKey, due: due)
        return out
    }
}

/// Where a deadline stands today.
enum DeadlineStatus {
    case done, overdue, today, soon, later, none

    static func of(due: String?, done: Bool, today: String = DateKey.string(Date())) -> DeadlineStatus {
        if done { return .done }
        guard let due else { return .none }
        if due < today { return .overdue }
        if due == today { return .today }
        if let t = DateKey.date(today), let s = Calendar.current.date(byAdding: .day, value: 3, to: t), due <= DateKey.string(s) { return .soon }
        return .later
    }
}

/// One deadline coming up (or missed) somewhere in a project, for the Today list.
struct ProjectDeadline: Identifiable {
    var project: Project
    var item: ProjectItem?
    /// Titles of the parents above it, for context ("Essay › Research").
    var path: [String]
    var due: String?
    var id: String { "\(project.id)|\(item?.id.uuidString ?? "project")" }
    var title: String { item?.title ?? project.title }
}

extension Project {
    /// Subtasks for today's list, which count in today's progress ring: urgent ones, and ones whose own
    /// deadline is within `window` days (0 = due today; overdue ones too). -1 = urgent ones only.
    /// Ones finished today stay on, so the ring fills up. `upcoming` is the rest due within 7 days,
    /// plus the project's own deadline: shown apart, not counted.
    func todayItems(window: Int, today: Date = Date()) -> (today: [ProjectDeadline], upcoming: [ProjectDeadline]) {
        guard archived != true else { return ([], []) }
        let cal = Calendar.current, t = today.startOfDay
        let limit = window >= 0 ? DateKey.string(cal.date(byAdding: .day, value: window, to: t) ?? t) : ""
        let week = DateKey.string(cal.date(byAdding: .day, value: 7, to: t) ?? t)
        var on: [ProjectDeadline] = [], later: [ProjectDeadline] = []
        var titles: [UUID: String] = [:], parents: [UUID: UUID] = [:]
        for r in rows() {
            titles[r.item.id] = r.item.title
            if let p = r.parentID { parents[r.item.id] = p }
            let i = r.item, done = i.isDone
            let doneToday = i.doneAt.map { cal.isDate($0, inSameDayAs: t) } ?? false
            let inWindow = window >= 0 && i.due.map { $0 <= limit } == true
            func entry() -> ProjectDeadline {
                var path: [String] = [], p = r.parentID
                while let id = p { path.insert(titles[id] ?? "", at: 0); p = parents[id] }
                return ProjectDeadline(project: self, item: i, path: path, due: i.due)
            }
            if i.isUrgent || inWindow {
                if !done || doneToday { on.append(entry()) }
            } else if !done, let d = i.due, d <= week {
                later.append(entry())
            }
        }
        if let d = due, !isDone, d <= week { later.append(ProjectDeadline(project: self, item: nil, path: [], due: d)) }
        return (on, later)
    }

    /// Its own deadline and every unfinished subtask's own deadline, up to `days` ahead (and any overdue).
    func deadlines(within days: Int, today: Date = Date()) -> [ProjectDeadline] {
        guard archived != true else { return [] }
        let limit = DateKey.string(Calendar.current.date(byAdding: .day, value: days, to: today.startOfDay) ?? today)
        var out: [ProjectDeadline] = []
        if let d = due, !isDone, d <= limit { out.append(ProjectDeadline(project: self, item: nil, path: [], due: d)) }
        var titles: [UUID: String] = [:], parents: [UUID: UUID] = [:]
        for r in rows() {
            titles[r.item.id] = r.item.title
            if let p = r.parentID { parents[r.item.id] = p }
            guard let d = r.item.due, !r.item.isDone, d <= limit else { continue }
            var path: [String] = [], p = r.parentID
            while let id = p { path.insert(titles[id] ?? "", at: 0); p = parents[id] }
            out.append(ProjectDeadline(project: self, item: r.item, path: path, due: d))
        }
        return out
    }
}

/// "Nov 20", or "Nov 20, 2027" outside this year.
func shortDay(_ key: String) -> String {
    guard let d = DateKey.date(key) else { return key }
    let sameYear = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year)
    return d.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())
}

/// "today", "tomorrow", "in 5 days", "2 days late".
func dueRelative(_ key: String, today: Date = Date()) -> String {
    guard let d = DateKey.date(key) else { return "" }
    let n = Calendar.current.dateComponents([.day], from: today.startOfDay, to: d.startOfDay).day ?? 0
    switch n {
    case 0: return "today"
    case 1: return "tomorrow"
    case -1: return "1 day late"
    case ..<0: return "\(-n) days late"
    default: return "in \(n) days"
    }
}

/// Tidy tree layout for the project map: leaves get their own row, a parent sits level with the middle of
/// its children. Same as projectMapLayout on the web.
struct ProjectMapLayout {
    struct Node: Identifiable { var id: UUID?; var item: ProjectItem?; var depth: Int; var y: Double }
    var nodes: [Node] = []
    var edges: [(from: UUID?, to: UUID?)] = []
    var rows = 1
    var depth = 0

    init(_ p: Project, collapsed: Set<UUID> = []) {
        var next = 0.0
        func place(_ item: ProjectItem?, children: [ProjectItem], depth: Int) -> Double {
            let kids = item.map { collapsed.contains($0.id) ? [] : $0.items } ?? children
            if kids.isEmpty {
                nodes.append(Node(id: item?.id, item: item, depth: depth, y: next)); next += 1
                return next - 1
            }
            let ys = kids.map { k -> Double in
                let y = place(k, children: k.items, depth: depth + 1)
                edges.append((item?.id, k.id))
                return y
            }
            let y = (ys.first! + ys.last!) / 2
            nodes.append(Node(id: item?.id, item: item, depth: depth, y: y))
            return y
        }
        _ = place(nil, children: p.items, depth: 0)
        rows = max(1, Int(next))
        depth = nodes.map(\.depth).max() ?? 0
    }
}

extension Project {
    /// Sample project for -demo screenshots: a science fair entry with nested subtasks and deadlines.
    static func demo(today: Date = Date()) -> Project {
        func k(_ n: Int) -> String { DateKey.string(Calendar.current.date(byAdding: .day, value: n, to: today.startOfDay)!) }
        func done(_ i: ProjectItem) -> ProjectItem {
            var i = i
            i.setDone(true, at: i.due.flatMap(DateKey.date) ?? Calendar.current.date(byAdding: .day, value: -2, to: today)!)
            return i
        }
        var p = Project(title: "Science fair: solar water heater", color: .orange, start: k(-12), due: k(24), items: [
            ProjectItem(title: "Research", due: k(-3), items: [
                done(ProjectItem(title: "Read 5 sources on solar heating", due: k(-8))),
                done(ProjectItem(title: "Write research summary", due: k(-4))),
            ]),
            ProjectItem(title: "Build the heater", start: k(-2), due: k(9), items: [
                done(ProjectItem(title: "Buy tubing and black paint", due: k(-1))),
                ProjectItem(title: "Build the box", due: k(2), items: [
                    done(ProjectItem(title: "Cut the panels")),
                    ProjectItem(title: "Glue and seal", due: k(1)),
                ]),
                { var i = ProjectItem(title: "Paint and test for leaks", due: k(5)); i.urgent = true; return i }(),
            ]),
            ProjectItem(title: "Experiment", start: k(6), due: k(16), items: [
                ProjectItem(title: "Run 3 trials in the sun", due: k(13)),
                ProjectItem(title: "Record temperatures every 10 min"),
            ]),
            ProjectItem(title: "Presentation", start: k(14), due: k(26), items: [
                ProjectItem(title: "Make graphs", due: k(18)),
                ProjectItem(title: "Print the poster", due: k(22)),
            ]),
            ProjectItem(title: "Email Ms. Lee about judging slot", due: k(-1)),
        ])
        p.createdAt = today.addingTimeInterval(-12 * 86_400)
        return p
    }
}
