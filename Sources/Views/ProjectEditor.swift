import AppKit
import SwiftUI

/// The project screen's working state: which subtasks are picked, undo/redo, the clipboard, and the keyboard.
/// Everything here also has a button, menu item or ghost box, so none of it needs a shortcut.
@MainActor
final class ProjectEditor: ObservableObject {
    var store: Store!
    var projectID = UUID()
    @Published var picked: Set<UUID> = []
    /// Where shift-click and shift-arrow extend from.
    var anchor: UUID?
    /// The subtask whose title is being typed in (mirrors the view's focus).
    var focused: UUID?
    /// Ask the view to put the cursor in this subtask's title.
    @Published var focusRequest: UUID?
    var collapsed: Set<UUID> = []
    @Published var showKeys = false

    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var lastKey: String?
    /// Shared between projects, so you can copy from one and paste into another.
    static var clipboard: [ProjectItem] = []


    var project: Project? { store?.project(projectID) }
    var rows: [Project.Row] { project?.rows(collapsed: collapsed) ?? [] }

    // MARK: Editing with undo

    /// Every change goes through here. Changes with the same `key` (typing in one title) undo together.
    func edit(_ key: String? = nil, _ change: (inout Project) -> Void) {
        guard let p = project else { return }
        if key == nil || key != lastKey {
            undoStack.append(p); if undoStack.count > 60 { undoStack.removeFirst() }
            redoStack = []
        }
        lastKey = key
        store.editProject(projectID, change)
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let before = undoStack.popLast(), let now = project else { return }
        redoStack.append(now); lastKey = nil
        store.editProject(projectID) { $0 = before }
        picked = picked.filter { before.item($0) != nil }
    }

    func redo() {
        guard let after = redoStack.popLast(), let now = project else { return }
        undoStack.append(now); lastKey = nil
        store.editProject(projectID) { $0 = after }
    }

    // MARK: Picking

    /// A click on a row or node: ⌘ adds/removes it, ⇧ picks the range from the last one, plain picks just it.
    func click(_ id: UUID, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) {
        if modifiers.contains(.command) {
            if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
            anchor = id
        } else if modifiers.contains(.shift), let a = anchor {
            picked.formUnion(range(a, id))
        } else {
            picked = picked == [id] ? [] : [id]
            anchor = id
        }
    }

    private func range(_ a: UUID, _ b: UUID) -> [UUID] {
        let ids = rows.map(\.id)
        guard let i = ids.firstIndex(of: a), let j = ids.firstIndex(of: b) else { return [b] }
        return Array(ids[min(i, j)...max(i, j)])
    }

    func pickAll() { picked = Set(project?.rows().map(\.id) ?? []) }

    /// Arrow keys without a cursor: move the pick up or down (⇧ extends it).
    func step(_ delta: Int, extend: Bool) {
        let ids = rows.map(\.id)
        guard !ids.isEmpty else { return }
        let cur = anchor.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        let next = ids[min(ids.count - 1, max(0, cur + delta))]
        if extend { picked.insert(next) } else { picked = [next] }
        anchor = next
    }

    /// What the bulk actions work on: the picked rows, or the one being typed in.
    var targets: [UUID] {
        let ids = picked.isEmpty ? Set(focused.map { [$0] } ?? []) : picked
        return project?.topMost(ids) ?? []
    }

    // MARK: Adding (ghost boxes, Return, ⇧Return)

    @discardableResult
    func add(under parent: UUID?, after: UUID? = nil, title: String = "") -> UUID {
        let n = ProjectItem(title: title)
        edit { $0.insert(n, under: parent, after: after) }
        if let parent { collapsed.remove(parent) }
        picked = [n.id]; anchor = n.id
        focusRequest = n.id
        return n.id
    }

    // MARK: Bulk changes

    func setDone(_ done: Bool) { let ids = targets; edit { p in for id in ids { p.update(id) { $0.setDone(done) } } } }

    func toggleDone() {
        let ids = targets
        guard let p = project else { return }
        let allDone = ids.allSatisfy { p.item($0)?.isDone == true }
        setDone(!allDone)
    }

    func toggleUrgent() {
        let ids = targets
        guard let p = project else { return }
        let allUrgent = ids.allSatisfy { p.item($0)?.isUrgent == true }
        edit { p in for id in ids { p.update(id) { $0.urgent = allUrgent ? nil : true } } }
    }

    func setDue(_ key: String?) { let ids = targets; edit { p in for id in ids { p.update(id) { $0.due = key } } } }
    func setStart(_ key: String?) { let ids = targets; edit { p in for id in ids { p.update(id) { $0.start = key } } } }

    func indent() { let ids = targets; edit { p in for id in ids { p.indent(id) } }; keepFocus() }
    func outdent() { let ids = targets; edit { p in for id in ids.reversed() { p.outdent(id) } }; keepFocus() }

    func move(_ delta: Int) {
        let ids = targets
        edit { p in for id in (delta < 0 ? ids : ids.reversed()) { p.move(id, by: delta) } }
        keepFocus()
    }

    private func keepFocus() { if let f = focused { focusRequest = f } }

    func delete() {
        let ids = targets
        guard !ids.isEmpty else { return }
        // Put the cursor (or pick) on the row above, so you can keep going from the keyboard.
        let order = rows.map(\.id)
        let above = ids.first.flatMap { order.firstIndex(of: $0) }.flatMap { $0 > 0 ? order[$0 - 1] : nil }
        let wasTyping = focused != nil && picked.isEmpty
        edit { p in for id in ids { p.remove(id) } }
        picked = []
        if let above { if wasTyping { focusRequest = above } else { picked = [above]; anchor = above } }
    }

    // MARK: Clipboard

    func copy() {
        guard let p = project else { return }
        Self.clipboard = targets.compactMap { p.item($0) }
    }

    func cut() { copy(); delete() }

    /// Pastes after the last picked row (same level), or at the end of the outline.
    func paste() {
        guard !Self.clipboard.isEmpty, let p = project else { return }
        let after = targets.last
        let parent = after.flatMap { p.parent(of: $0) }
        let copies = Self.clipboard.map { $0.cloned() }
        edit { proj in
            var prev = after
            for c in copies { proj.insert(c, under: parent, after: prev); prev = c.id }
        }
        picked = Set(copies.map(\.id)); anchor = copies.last?.id
    }

    func duplicate() { copy(); paste() }

    // MARK: Keyboard

    /// Returns true when the key was used.
    func handle(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
        let typing = NSApp.keyWindow?.firstResponder is NSText
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let code = e.keyCode
        let (tab, ret, esc, del, fwdDel, up, down, space) = (code == 48, code == 36 || code == 76, code == 53, code == 51, code == 117, code == 126, code == 125, code == 49)

        if typing {
            guard let f = focused else { return false }
            switch true {
            case tab && mods == []: indent(); return true
            case tab && mods == .shift: outdent(); return true
            case ret && mods == .shift: add(under: f); return true
            case ret && mods == .command: toggleDone(); return true
            case up && mods == .option: move(-1); return true
            case down && mods == .option: move(1); return true
            case (up || down) && mods == []:
                let ids = rows.map(\.id)
                if let i = ids.firstIndex(of: f) { let j = i + (up ? -1 : 1); if ids.indices.contains(j) { focusRequest = ids[j] } }
                return true
            case del && mods == [] && (project?.item(f)?.title.isEmpty ?? false): delete(); return true
            case esc:
                picked = [f]; anchor = f; focused = nil
                NSApp.keyWindow?.makeFirstResponder(nil)
                return true
            default: return false
            }
        }

        switch true {
        case mods == .command && key == "z": undo(); return true
        case mods == [.command, .shift] && key == "z": redo(); return true
        case mods == .command && key == "a": pickAll(); return true
        case mods == .command && key == "c" && !targets.isEmpty: copy(); return true
        case mods == .command && key == "x" && !targets.isEmpty: cut(); return true
        case mods == .command && key == "v": paste(); return true
        case mods == .command && key == "d" && !targets.isEmpty: duplicate(); return true
        case mods == .command && key == "/": showKeys.toggle(); return true
        case esc: if picked.isEmpty { return false }; picked = []; return true
        case (up || down) && (mods == [] || mods == .shift): step(up ? -1 : 1, extend: mods == .shift); return true
        case (up || down) && mods == .option && !targets.isEmpty: move(up ? -1 : 1); return true
        case picked.isEmpty: return false
        case tab && mods == []: indent(); return true
        case tab && mods == .shift: outdent(); return true
        case ret && mods == [] && picked.count == 1: focusRequest = picked.first; return true
        case ret && mods == .shift && picked.count == 1: add(under: picked.first); return true
        case ret && mods == .command: add(under: project?.parent(of: targets.last ?? UUID()), after: targets.last); return true
        case space && mods == []: toggleDone(); return true
        case (del || fwdDel) && mods == []: delete(); return true
        case key == "u" && mods == []: toggleUrgent(); return true
        default: return false
        }
    }

    static let shortcuts: [(String, String)] = [
        ("Return", "New subtask below (while typing) · edit the picked one"),
        ("⇧ Return", "New subtask inside this one"),
        ("Tab / ⇧ Tab", "Move in a level / out a level"),
        ("↑ ↓", "Move between subtasks (⇧ to pick several)"),
        ("⌥ ↑ / ⌥ ↓", "Move it up or down"),
        ("⌘ Return / Space", "Done / not done"),
        ("U", "Urgent on or off"),
        ("Delete", "Delete (or Backspace in an empty title)"),
        ("Esc", "Stop typing and pick the row · clear the pick"),
        ("⌘-click / ⇧-click", "Pick several · pick a range"),
        ("⌘A", "Pick everything"),
        ("⌘C ⌘X ⌘V ⌘D", "Copy, cut, paste, duplicate"),
        ("⌘Z / ⇧⌘Z", "Undo / redo"),
        ("⌘/", "Show these shortcuts"),
    ]
}

/// Installs the project keyboard handler while the project is on screen.
struct ProjectKeys: ViewModifier {
    @ObservedObject var editor: ProjectEditor
    @State private var monitor: Any?
    func body(content: Content) -> some View {
        content
            .onAppear {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak editor] e in
                    MainActor.assumeIsolated {
                        guard let editor, NSApp.keyWindow?.attachedSheet == nil else { return e }
                        return editor.handle(e) ? nil : e
                    }
                }
            }
            .onDisappear { if let m = monitor { NSEvent.removeMonitor(m) }; monitor = nil }
    }
}

/// Appears when subtasks are picked: change them all at once. Each button names its shortcut.
struct ProjectPickBar: View {
    @ObservedObject var editor: ProjectEditor
    @State private var dueDate = Date()
    @State private var pickingDue = false

    var body: some View {
        let n = editor.picked.count
        HStack(spacing: 6) {
            Text("\(n) picked").font(.app(.callout).weight(.semibold))
            Button { editor.toggleDone() } label: { Label("Done", systemImage: "checkmark.circle") }.help("Done / not done (Space)")
            Button { editor.toggleUrgent() } label: { Label("Urgent", systemImage: "exclamationmark.circle") }.help("Urgent on or off (U)")
            Menu {
                Button("Today") { editor.setDue(DateKey.string(Date())) }
                Button("Tomorrow") { editor.setDue(DateKey.string(Date().adding(days: 1))) }
                Button("In a week") { editor.setDue(DateKey.string(Date().adding(days: 7))) }
                Button("Pick a day…") { pickingDue = true }
                Divider()
                Button("No deadline") { editor.setDue(nil) }
            } label: { Label("Deadline", systemImage: "flag") }.fixedSize()
            .popover(isPresented: $pickingDue) {
                VStack {
                    DatePicker("", selection: $dueDate, displayedComponents: .date).datePickerStyle(.graphical).labelsHidden()
                    Button("Set deadline") { editor.setDue(DateKey.string(dueDate)); pickingDue = false }.keyboardShortcut(.defaultAction)
                }.padding()
            }
            Button { editor.outdent() } label: { Image(systemName: "arrow.left") }.help("Move out a level (⇧Tab)")
            Button { editor.indent() } label: { Image(systemName: "arrow.right") }.help("Move in a level (Tab)")
            Button { editor.move(-1) } label: { Image(systemName: "arrow.up") }.help("Move up (⌥↑)")
            Button { editor.move(1) } label: { Image(systemName: "arrow.down") }.help("Move down (⌥↓)")
            Button { editor.copy() } label: { Image(systemName: "doc.on.doc") }.help("Copy (⌘C)")
            Button { editor.duplicate() } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate (⌘D)")
            Button(role: .destructive) { editor.delete() } label: { Image(systemName: "trash") }.help("Delete (Delete)")
            Spacer()
            Button("Clear") { editor.picked = [] }.help("Esc")
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.10)))
    }
}

/// The ⌨ button: every shortcut, in plain words.
struct ProjectKeysButton: View {
    @ObservedObject var editor: ProjectEditor
    var body: some View {
        Button { editor.showKeys.toggle() } label: { Image(systemName: "keyboard") }
            .buttonStyle(.borderless)
            .help("Keyboard shortcuts (⌘/)")
            .popover(isPresented: $editor.showKeys) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keyboard shortcuts").font(.app(.headline))
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                        ForEach(ProjectEditor.shortcuts, id: \.0) { k, v in
                            GridRow { Text(k).font(.callout.monospaced().weight(.semibold)); Text(v).font(.app(.callout)).foregroundStyle(.secondary) }
                        }
                    }
                    Text("None of these are required: the + boxes add subtasks, the bar above the list changes the picked rows, and right-clicking a row shows the other actions.")
                        .font(.app(.caption)).foregroundStyle(.secondary).frame(width: 380, alignment: .leading)
                }
                .padding(16)
            }
    }
}

