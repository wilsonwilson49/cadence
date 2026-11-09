import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: Store

    private var selection: Binding<Screen?> {
        Binding(get: { model.screen }, set: { if let s = $0 { model.screen = s } })
    }

    var body: some View {
        NavigationSplitView {
            // Header and footer sit outside the List (no safeAreaInset): insets on a macOS sidebar
            // List can shift where clicks land, which made the first row under each header miss.
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 28, height: 28)
                    Text("Cadence").font(.title3.weight(.bold))
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 2)

                List(selection: selection) {
                    Section {
                        row(.home)
                    }
                    ForEach(SidebarGroup.all.filter { !hidden.contains($0.name) }) { g in
                        Section(isExpanded: expandedBinding(g.name)) {
                            ForEach(g.screens, id: \.self) { s in row(s, badge: badge(s)) }
                        } header: {
                            Text(g.name)
                                .contextMenu {
                                    Button("Hide \(g.name)") { setHidden(g.name, true) }
                                    Button("Show hidden sections") { hiddenRaw = "" }.disabled(hidden.isEmpty)
                                }
                        }
                    }
                    Section {
                        row(.settings)
                    }
                }
                .listStyle(.sidebar)

                VStack(alignment: .leading, spacing: 6) {
                    Button { model.newTask() } label: {
                        Label("New Task", systemImage: "plus").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("n", modifiers: .command)
                    Button { model.newEvent() } label: {
                        Label("New Event", systemImage: "calendar.badge.plus").frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    SyncIndicator()
                }
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .sheet(item: $model.reflectionTarget) { occ in
            ReflectionForm(occurrence: occ, minWords: store.settings.minReflectionWords, missed: model.reflectionMissed) { text in
                if model.reflectionMissed { store.miss(occ, reflection: text) } else { store.complete(occ, reflection: text) }
                model.reflectionTarget = nil
            } onCancel: {
                model.reflectionTarget = nil
            }
        }
        .sheet(item: $model.editingTask) { task in
            TaskEditor(task: task, isNew: store.task(task.id) == nil)
        }
    }

    // Sidebar sections: click a heading to fold it; right-click to hide it (Settings › Sidebar brings it back).
    @AppStorage("sidebarCollapsed") private var collapsedRaw = ""
    @AppStorage("sidebarHidden") private var hiddenRaw = ""
    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }
    private var hidden: Set<String> { Set(hiddenRaw.split(separator: ",").map(String.init)) }
    private func expandedBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(name) }, set: { open in
            var c = collapsed
            if open { c.remove(name) } else { c.insert(name) }
            collapsedRaw = c.sorted().joined(separator: ",")
        })
    }
    private func setHidden(_ name: String, _ on: Bool) {
        var h = hidden
        if on { h.insert(name) } else { h.remove(name) }
        hiddenRaw = h.sorted().joined(separator: ",")
    }

    private func badge(_ s: Screen) -> Int {
        switch s {
        case .today: return store.remainingToday
        case .projects: return store.projectToday().filter { $0.item?.isDone == false }.count
        case .habits: return store.countedToday().filter { $0.isHabit && !$0.isUntilDone && !$0.isResolved }.count
        case .reflections: return store.reflections.count
        case .flashcards: return store.dueCardCount
        default: return 0
        }
    }

    private func row(_ s: Screen, badge: Int = 0) -> some View {
        Label(s.title, systemImage: s.symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // Belt and braces: a click anywhere on the row switches screens even if List selection misses it.
            .simultaneousGesture(TapGesture().onEnded { model.screen = s })
            .badge(badge)
            .tag(s)
    }

    @ViewBuilder private var detail: some View {
        switch model.screen {
        case .home: HomeView()
        case .today: TodayView()
        case .week: WeekView()
        case .month: MonthView()
        case .todo: TodoView()
        case .projects: ProjectsView()
        case .study: StudyView()
        case .flashcards: FlashcardsView()
        case .notes: NotesView()
        case .reflections: ReflectionsView()
        case .habits: HabitsView()
        case .focus: FocusView()
        case .screentime: ScreenTimeView()
        case .booking: BookingView()
        case .settings: SettingsView()
        }
    }
}

/// The sidebar's sections. Each can be folded (click its heading) or hidden (right-click, or Settings › Sidebar).
struct SidebarGroup: Identifiable {
    let name: String
    let screens: [Screen]
    var id: String { name }
    static let all: [SidebarGroup] = [
        SidebarGroup(name: "Plan", screens: [.today, .week, .month, .todo, .projects]),
        SidebarGroup(name: "Study", screens: [.study, .flashcards]),
        SidebarGroup(name: "Grow", screens: [.habits, .reflections]),
        SidebarGroup(name: "Focus", screens: [.focus, .screentime]),
        SidebarGroup(name: "Tools", screens: [.notes]),
        SidebarGroup(name: "Connect", screens: [.booking]),
    ]
}
